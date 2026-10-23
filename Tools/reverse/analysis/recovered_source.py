"""Resolve recovered managed C# through the recovery index and manifest.

`recover_managed.py` keeps the primary ILSpy project unchanged, even where it
contains error stubs, and records clean whole-type fallback exports for the
types named in the primary failure log. Consumers must not guess paths into
that tree: this resolver returns a type from the manifest-selected project,
uses a per-type fallback only where the manifest records a clean one, and
refuses error stubs, missing types, changed files and ambiguous matches by
name. Every refusal is a `RecoveredSourceError` (a `ValueError`).
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re

try:  # Run as a script or from Tools/reverse/analysis.
    from recover_managed import has_error_stub, project_file
except ImportError:  # Imported as analysis.recovered_source from Tools/reverse.
    from analysis.recover_managed import has_error_stub, project_file

MAIN_GAME = 'Koikatu_Data/Managed/Assembly-CSharp.dll'
FIRSTPASS = 'Koikatu_Data/Managed/Assembly-CSharp-firstpass.dll'


class RecoveredSourceError(ValueError):
    """The recovery cannot supply trustworthy source for the request."""


class RecoveryManifestError(RecoveredSourceError):
    """The index or manifest is unreadable, inconsistent or selects no project."""


class MissingRecoveredSource(RecoveredSourceError):
    """The index lists no such assembly, or its manifest records no such type."""


class AmbiguousRecoveredSource(RecoveredSourceError):
    """More than one assembly generation, fallback or project file matches."""


class RecoveredHashMismatch(RecoveredSourceError):
    """A file, assembly or manifest differs from its recorded identity."""


class RecoveredErrorStub(RecoveredSourceError):
    """The only recorded source for the type is an error stub or an unclean fallback."""


def arity_free(type_name: str) -> str:
    return re.sub(r'`\d+', '', type_name)


@dataclass(frozen=True)
class RecoveredSource:
    type: str
    path: Path
    sha256: str
    origin: str  # 'project' or 'type-fallback'
    data: bytes = field(repr=False)

    @property
    def text(self) -> str:
        # Same decoding and newline translation as Path.read_text().
        return io.TextIOWrapper(io.BytesIO(self.data)).read()


class RecoveredAssembly:
    """One assembly's indexed recovery generation, selected by source path or SHA-256."""

    def __init__(self, index_path: Path, *, source_path: str | None = None, sha256: str | None = None):
        if (source_path is None) == (sha256 is None):
            raise TypeError('Select the recovered assembly by exactly one of source_path or sha256')
        request = source_path or sha256
        self.index_path = Path(index_path)

        def selected(entry):
            if source_path is None:
                return entry['assemblySHA256'] == sha256
            if not isinstance(entry['sourcePaths'], list):
                raise TypeError('sourcePaths is not a list')
            return source_path in entry['sourcePaths']
        try:
            matches = [entry for entry in json.loads(self.index_path.read_text())['assemblies'] if selected(entry)]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise RecoveryManifestError(f'Unreadable recovery index {self.index_path}: {error}') from error
        if not matches:
            raise MissingRecoveredSource(f'Recovery index lists no assembly for {request}')
        if len({str(entry.get('directory')) for entry in matches}) > 1:
            raise AmbiguousRecoveredSource(f'Recovery index lists several generations for {request}')
        self.entry = entry = matches[0]
        try:
            self.directory = Path(entry['directory'])
            self.assembly_sha256 = entry['assemblySHA256']
            self.selected_project = entry['selectedProject']
            self.status = entry.get('status')
            manifest = json.loads((self.directory / 'manifest.json').read_text())
            identities = {manifest['identity']['assemblySHA256'], manifest['summary']['assemblySHA256']}
            manifest_project = manifest['summary']['selectedProject']
            self.files = {item['path']: item for item in manifest['files']}
            self.overrides = list(manifest.get('typeOverrides', []))
            self.diagnostic_files = {item['file'] for item in manifest.get('decompilerDiagnostics', [])}
            self.failed_types = {arity_free(item['member'].rsplit('.', 1)[0].rstrip('.'))
                                 for item in manifest.get('primaryDecompilerErrors', [])}
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            raise RecoveryManifestError(f'Unreadable recovery manifest for {request}: {error}') from error
        if identities != {self.assembly_sha256}:
            raise RecoveredHashMismatch(f'Recovery manifest identity differs from the index for {request}')
        if manifest_project != self.selected_project:
            raise RecoveryManifestError(f'Recovery index and manifest select different projects for {request}')
        project = self.selected_project
        if not isinstance(project, str) or PurePosixPath(project).parts != (project,) or project == '..':
            # recover_managed.py selects no project while a failed type lacks a clean fallback.
            raise RecoveryManifestError(f'Recovery selects no usable project for {request}: {project!r}')

    def verify_assembly(self) -> None:
        """Check that the recorded original DLL still has the recovered SHA-256."""
        try:
            actual = hashlib.sha256(Path(self.entry['assembly']).read_bytes()).hexdigest()
        except (OSError, KeyError, TypeError) as error:
            raise RecoveredHashMismatch(f'Recovered assembly is unavailable: {error}') from error
        if actual != self.assembly_sha256:
            raise RecoveredHashMismatch(f'Managed assembly provenance changed: {self.entry["assembly"]}')

    def source(self, type_name: str) -> RecoveredSource:
        """Manifest-selected source for a namespace-qualified type name."""
        fallback = self._fallback(type_name)
        if fallback is not None:
            return self._read(type_name, fallback['file'], 'type-fallback')
        if arity_free(type_name) in self.failed_types:
            raise RecoveredErrorStub(f'Primary decompilation failed for {type_name} and no clean fallback is recorded')
        return self._read(type_name, self._primary(type_name), 'project')

    def _fallback(self, type_name: str) -> dict | None:
        # Overrides carry metadata names with generic arity; an arity-free
        # request selects one only when that is unambiguous.
        matches = [item for item in self.overrides if item.get('type') == type_name] or \
                  [item for item in self.overrides if arity_free(str(item.get('type'))) == type_name]
        if len(matches) > 1:
            raise AmbiguousRecoveredSource(f'Several type fallbacks match {type_name}: {[item["type"] for item in matches]}')
        if not matches:
            return None
        item = matches[0]
        # The primary already failed for this type: an unclean fallback never
        # falls back further to the primary project file.
        if item.get('exitCode') != 0 or item.get('timedOut') is not False or item.get('hasErrorStub') is not False:
            raise RecoveredErrorStub(f'Type fallback for {type_name} did not complete cleanly: {item}')
        return item

    def _primary(self, type_name: str) -> str:
        namespace, _, name = type_name.rpartition('.')
        # The recovery's dotted namespace directory, or a nested one; never both.
        candidates = sorted({project_file(self.selected_project, type_name),
                             project_file('/'.join([self.selected_project, *namespace.split('.')]), name)})
        recorded = [path for path in candidates if path in self.files]
        if len(recorded) > 1:
            raise AmbiguousRecoveredSource(f'Several selected-project files match {type_name}: {recorded}')
        if not recorded:
            if any((self.directory / path).exists() for path in candidates):
                raise RecoveredHashMismatch(f'Source for {type_name} is present but not recorded in the recovery manifest')
            raise MissingRecoveredSource(f'Missing selected recovered type: {type_name}')
        return recorded[0]

    def _read(self, type_name: str, relative: str, origin: str) -> RecoveredSource:
        entry = self.files.get(relative)
        path = self.directory / relative
        if entry is None:
            raise RecoveredHashMismatch(f'{relative} is not recorded in the recovery manifest')
        if not path.resolve().is_relative_to(self.directory.resolve()) or not path.is_file():
            raise RecoveredHashMismatch(f'Recorded recovered source is unavailable: {path}')
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != entry.get('bytes') or digest != entry.get('sha256'):
            raise RecoveredHashMismatch(f'Recovered source differs from its manifest hash: {path}')
        if not data or relative in self.diagnostic_files or has_error_stub(data.decode(errors='replace')):
            raise RecoveredErrorStub(f'Selected recovered source contains a decompiler error stub: {type_name} ({relative})')
        return RecoveredSource(type=type_name, path=path, sha256=digest, origin=origin, data=data)
