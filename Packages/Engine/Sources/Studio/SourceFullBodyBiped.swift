import Foundation
import simd
import CoreMath
import Scene

/// Original serialized FinalIK settings. Identities are bound before any frame runs.
public struct SourceFullBodySettings: Decodable, Sendable {
    typealias Reference = SourceStudioIK.Bindings.NodeReference
    struct Constraint: Decodable, Sendable { let bone1, bone2: Reference; let pushElasticity, pullElasticity: Float }
    struct Chain: Decodable, Sendable {
        let nodes: [Reference], children: [Int], constraints: [Constraint]
        let pin, pull, push, pushParent, reach, bendWeight: Float
        let reachSmoothing, pushSmoothing: Int
    }
    struct Effector: Decodable, Sendable {
        let bone: Reference, children: [Reference], plane: [Reference]
        let effectChildNodes: Bool
        let positionWeight, rotationWeight, maintainRelativePositionWeight: Float
    }
    struct Spine: Decodable, Sendable { let bones: [Reference]; let iterations: Int; let twistWeight: Float }
    struct Bone: Decodable, Sendable { let bone: Reference; let maintainRotationWeight: Float }
    struct Limb: Decodable, Sendable { let parent: Reference?; let bones: [Reference]; let maintainRotationWeight, weight: Float }
    let weight, spineStiffness: Float
    let chains: [Chain], effectors: [Effector], spine: Spine, bones: [Bone], limbs: [Limb]
}

/// Stateless native execution of the recovered biped stages. Each frame starts
/// from an explicit initialization pose and the supplied animated/FK pose.
struct SourceFullBodyBiped: Sendable {
    let settings: SourceFullBodySettings
    let chainBones: [[Int]], effectorBones: [Int], effectorChildren: [[Int]], effectorPlanes: [[Int]]
    let constraints: [[(Int, Int)]], spine: [Int], headBones: [Int], shoulderParents: [Int?]
    let initialPose: RigPose
    let requiredBones: Set<Int>
    init(rig: RigDefinition, settings: SourceFullBodySettings, initialPose: RigPose,
         bind: (SourceStudioIK.Bindings.NodeReference) throws -> Int) throws {
        func unit(_ values: [Float]) -> Bool { values.allSatisfy { $0.isFinite && (0...1).contains($0) } }
        guard settings.chains.count == 5, settings.effectors.count == 9, settings.limbs.count == 4,
              (3...32).contains(settings.spine.bones.count), (1...16).contains(settings.spine.iterations),
              unit([settings.weight, settings.spineStiffness, settings.spine.twistWeight]), settings.bones.count <= 8 else {
            throw RigError.invalid("Unsupported full-body solver topology/settings.")
        }
        let chainBones = try settings.chains.map { try $0.nodes.map(bind) }
        self.chainBones = chainBones
        guard chainBones.map(\.count) == [1,3,3,3,3], Set(chainBones.flatMap { $0 }).count == 13,
              settings.chains[0].children == [1,2,3,4], settings.chains[0].constraints.count == 4 else {
            throw RigError.invalid("Full-body chain identities differ from the recovered biped topology.")
        }
        for (index, chain) in settings.chains.enumerated() {
            guard unit([chain.pin,chain.pull,chain.push,chain.reach,chain.bendWeight]), chain.pushParent.isFinite,
                  (-1...1).contains(chain.pushParent), (0...2).contains(chain.reachSmoothing), (0...2).contains(chain.pushSmoothing),
                  index == 0 || (chain.children.isEmpty && chain.constraints.isEmpty),
                  chain.constraints.allSatisfy({ unit([$0.pushElasticity,$0.pullElasticity]) }) else {
                throw RigError.invalid("Invalid full-body chain/constraint parameters.")
            }
        }
        let flat = Set(chainBones.flatMap { $0 })
        effectorBones = try settings.effectors.map { try bind($0.bone) }
        effectorChildren = try settings.effectors.map { try $0.children.map(bind) }
        effectorPlanes = try settings.effectors.map { try $0.plane.map(bind) }
        guard effectorBones == [chainBones[0][0]] + (1...4).map({ chainBones[$0][0] }) + (1...4).map({ chainBones[$0][2] }) else {
            throw RigError.invalid("Full-body effectors differ from source biped ordering.")
        }
        for (index, e) in settings.effectors.enumerated() {
            guard unit([e.positionWeight,e.rotationWeight,e.maintainRelativePositionWeight]),
                  effectorChildren[index].allSatisfy(flat.contains), Set(effectorChildren[index]).count == e.children.count,
                  effectorPlanes[index].count == (index < 5 ? 0 : 3), Set(effectorPlanes[index]).count == effectorPlanes[index].count, effectorPlanes[index].allSatisfy(flat.contains) else {
                throw RigError.invalid("Invalid full-body effector plane or child binding.")
            }
        }
        constraints = try settings.chains.map { chain in try chain.constraints.map { c in
            let a = try bind(c.bone1), b = try bind(c.bone2)
            guard let x = chainBones.firstIndex(where: { $0[0] == a }), let y = chainBones.firstIndex(where: { $0[0] == b }), x > 0, y > 0, x != y else {
                throw RigError.invalid("Full-body child constraint does not join distinct proximal nodes.")
            }
            return (x,y)
        } }
        spine = try settings.spine.bones.map(bind); headBones = try settings.bones.map { try bind($0.bone) }
        shoulderParents = try settings.limbs.map { try $0.parent.map(bind) }
        guard spine.filter(flat.contains) == [chainBones[0][0]], Set(spine).count == spine.count,
              settings.bones.allSatisfy({ unit([$0.maintainRotationWeight]) }) else { throw RigError.invalid("Invalid full-body spine/head mapping.") }
        for i in 0..<4 {
            guard try settings.limbs[i].bones.map(bind) == chainBones[i+1], unit([settings.limbs[i].weight, settings.limbs[i].maintainRotationWeight]) else {
                throw RigError.invalid("Full-body limb mapping differs from its chain.")
            }
        }
        self.settings = settings; self.initialPose = initialPose
        var required = Set(chainBones.flatMap { $0 } + spine + headBones + shoulderParents.compactMap { $0 })
        for bone in Array(required) {
            var ancestor = rig.nodes[bone].parent
            while let node = ancestor { required.insert(node); ancestor = rig.nodes[node].parent }
        }
        requiredBones = required
        _ = try BodyTransforms(rig: rig, pose: initialPose, required: required)
    }
    func solve(rig: RigDefinition, pose: RigPose, guides: [SourceStudioIK.Guide], active: [Bool], iterations: Int,
               root: Int, vertical: Float, horizontal: Float) throws -> (RigPose, Float3, [[Float3]]) {
        if settings.weight <= 0 { return (pose, .zero, []) }
        let frame = try BodySolver(binding: self, rig: rig, pose: pose, guides: guides, active: active, iterations: iterations)
        try frame.solve(root: root, vertical: vertical, horizontal: horizontal)
        return (try frame.transforms.pose(), UnityCoordinates.position(frame.pull), frame.chains.map { $0.nodes.map(\.p) })
    }
}

// Unity quaternion composition must be independent of affine world matrices:
// nonuniform parents legitimately shear child matrices, while Transform.rotation
// remains the quaternion product of local rotations.
private final class BodyTransforms {
    let rig: RigDefinition, originalPose: RigPose, required: Set<Int>
    var positions: [Float3] = [], rotations: [simd_quatf] = [], scales: [Float3] = []
    init(rig: RigDefinition, pose: RigPose, required: Set<Int>) throws {
        self.rig = rig; originalPose = pose; self.required = required
        guard pose.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Full-body pose size differs from rig.") }
        for (i, native) in pose.localMatrices.enumerated() {
            guard required.contains(i) else { positions.append(.zero); rotations.append(.identity); scales.append(.one); continue }
            let m = UnityCoordinates.matrix(native)
            let axes = [Float3(m[0].x,m[0].y,m[0].z), Float3(m[1].x,m[1].y,m[1].z), Float3(m[2].x,m[2].y,m[2].z)]
            let scale = Float3(simd_length(axes[0]),simd_length(axes[1]),simd_length(axes[2]))
            guard scale.x > 1e-7, scale.y > 1e-7, scale.z > 1e-7, scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
                  rig.nodes[i].scale.x > 0, rig.nodes[i].scale.y > 0, rig.nodes[i].scale.z > 0 else {
                throw RigError.invalid("Full-body IK requires finite positive local scales.")
            }
            let basis = float3x3(columns: (axes[0]/scale.x,axes[1]/scale.y,axes[2]/scale.z))
            guard abs(simd_determinant(basis)-1) < 0.0002,
                  abs(simd_dot(basis[0],basis[1])) < 0.0002, abs(simd_dot(basis[0],basis[2])) < 0.0002, abs(simd_dot(basis[1],basis[2])) < 0.0002 else {
                throw RigError.invalid("Full-body IK cannot decompose authored local shear/reflections.")
            }
            let p = Float3(m[3].x,m[3].y,m[3].z)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { throw RigError.invalid("Nonfinite full-body local position.") }
            positions.append(p); rotations.append(simd_quatf(basis).normalized); scales.append(scale)
        }
    }
    func matrix(_ i: Int) -> float4x4 {
        let local = Transform.trs(positions[i],rotations[i],scales[i])
        return rig.nodes[i].parent.map { matrix($0)*local } ?? local
    }
    func p(_ i: Int) -> Float3 { let m=matrix(i); return Float3(m[3].x,m[3].y,m[3].z) }
    func q(_ i: Int) -> simd_quatf { rig.nodes[i].parent.map { q($0)*rotations[i] } ?? rotations[i] }
    func setP(_ i: Int, _ p: Float3) {
        let v = rig.nodes[i].parent.map { matrix($0).inverse * Float4(p,1) } ?? Float4(p,1)
        positions[i] = Float3(v.x,v.y,v.z)
    }
    func setQ(_ i: Int, _ value: simd_quatf) { rotations[i] = (rig.nodes[i].parent.map { q($0).inverse * value } ?? value).normalized }
    func pose() throws -> RigPose {
        var matrices = originalPose.localMatrices
        for i in required { matrices[i] = UnityCoordinates.matrix(Transform.trs(positions[i],rotations[i],scales[i])) }
        guard matrices.allSatisfy({ m in (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } } }) else { throw RigError.invalid("Full-body solve produced a nonfinite pose.") }
        var result = rig.restPose; result.localMatrices = matrices; return result
    }
}

private enum BodyMath {
    static func clamp(_ x: Float, _ lo: Float = 0, _ hi: Float = 1) -> Float { min(hi,max(lo,x)) }
    static func normalized(_ v: Float3) -> Float3 { let l=simd_length(v); return l > 0.00001 ? v/l : .zero }
    static func equal(_ a: Float3, _ b: Float3) -> Bool { simd_length_squared(a-b) < 9.99999944e-11 }
    static func perp(_ n: Float3) -> Float3 { normalized(abs(n.z)>0.70710678 ? Float3(0,-n.z,n.y):Float3(-n.y,n.x,0)) }
    static func ortho(_ normal: Float3, _ tangent: Float3) -> Float3 {
        let n=simd_length(normal)>0.00001 ? normalized(normal):Float3(1,0,0)
        let t=tangent-n*simd_dot(n,tangent)
        return simd_length(t)>0.00001 ? normalized(t):perp(n)
    }
    static func lerp(_ a: Float3, _ b: Float3, _ w: Float) -> Float3 { a+(b-a)*clamp(w) }
    static func qlerp(_ a: simd_quatf, _ b: simd_quatf, _ w: Float) -> simd_quatf {
        let v=simd_dot(a.vector,b.vector)<0 ? -b.vector:b.vector
        return simd_quatf(vector: a.vector+(v-a.vector)*clamp(w)).normalized
    }
    static func fromTo(_ a: Float3, _ b: Float3) -> simd_quatf {
        guard simd_length_squared(a)>1e-12,simd_length_squared(b)>1e-12 else { return .identity }
        let a=normalized(a),b=normalized(b),d=clamp(simd_dot(a,b),-1,1)
        if d>0.999999 { return .identity }; if d < -0.999999 { return simd_quatf(angle: .pi,axis: perp(a)) }
        return simd_quatf(vector: Float4(simd_cross(a,b),1+d)).normalized
    }
    static func look(_ forward: Float3, _ up: Float3) -> simd_quatf {
        guard simd_length_squared(forward)>1e-12 else { return .identity }
        let f=normalized(forward),r=normalized(simd_cross(up,f))
        if simd_length_squared(r)<1e-12 { return fromTo(Float3(0,0,1),f) }
        return simd_quatf(float3x3(columns: (r,simd_cross(f,r),f))).normalized
    }
    static func slerp(_ a: Float3, _ b: Float3, _ weight: Float) -> Float3 {
        let w=clamp(weight),la=simd_length(a),lb=simd_length(b)
        if la<1e-6 || lb<1e-6 { return lerp(a,b,w) }
        let an=a/la,bn=b/lb,d=clamp(simd_dot(an,bn),-1,1),angle=acos(d)
        let direction: Float3
        if d>0.9995 { direction=normalized(lerp(an,bn,w)) }
        else if d < -0.9995 { direction=simd_quatf(angle: angle*w,axis: perp(an)).act(an) }
        else { direction=(an*sin((1-w)*angle)+bn*sin(w*angle))/sin(angle) }
        return direction*(la+(lb-la)*w)
    }
    static func joint(_ a: Float3, _ b: Float3, _ length: Float) -> Float3 { b+normalized(a-b)*length }
}

private final class BodyNode {
    let bone: Int
    var p: Float3, q: simd_quatf = .identity, offset=Float3.zero, length: Float=0, posWeight: Float=0, rotWeight: Float=0
    init(_ bone: Int, _ p: Float3) { self.bone=bone;self.p=p }
}
private final class BodyChain {
    let nodes: [BodyNode]
    var rootLength: Float=0, length: Float=0, distance: Float=0, reachForce: Float=0, pullSum: Float=1
    var crossFades: [Float]=[], defaultDirection=Float3.zero, defaultChild=Float3.zero, direction=Float3.zero
    init(_ nodes: [BodyNode]) { self.nodes=nodes }
}
private struct BodyConstraint { let a,b: Int; var distance,push,pull,cross: Float }
private final class BodyEffector {
    let node: BodyNode, children: [BodyNode], plane: [BodyNode]
    let target: Float3, rotation: simd_quatf, weight: Float, relative: Float, effectChildren: Bool
    var childPositions: [Float3]=[], animated=Float3.zero, animatedPlane: simd_quatf = .identity, planeOffset: simd_quatf = .identity
    init(node: BodyNode, children: [BodyNode], plane: [BodyNode], guide: SourceStudioIK.Guide, weight: Float, relative: Float, effectChildren: Bool) {
        self.node=node;self.children=children;self.plane=plane;target=UnityCoordinates.position(guide.position);rotation=UnityCoordinates.rotation(guide.rotation)
        self.weight=weight;self.relative=relative;self.effectChildren=effectChildren
    }
}
private struct BodyMap {
    let bone: Int, plane: [BodyNode]
    var localRotation: simd_quatf = .identity, planePosition=Float3.zero, swing=Float3.zero, twist=Float3.zero, ik=Float3.zero, length: Float=0
    func planeRotation(animated: BodyTransforms? = nil) -> simd_quatf {
        let p=plane.map { animated?.p($0.bone) ?? $0.p }
        return BodyMath.equal(p[0],p[2]) ? .identity : BodyMath.look(p[1]-p[0],p[2]-p[0])
    }
    mutating func read(_ t: BodyTransforms, position: Bool = true) {
        let rotation=planeRotation(animated:t)
        localRotation=rotation.inverse*t.q(bone)
        if position { planePosition=rotation.inverse.act(t.p(bone)-t.p(plane[0].bone)) }
    }
    func writeRotation(_ t: BodyTransforms, weight: Float=1) { t.setQ(bone,BodyMath.qlerp(t.q(bone),planeRotation()*localRotation,weight)) }
    func planePoint() -> Float3 { plane[0].p+planeRotation().act(planePosition) }
    func swingTo(_ p: Float3, _ t: BodyTransforms, weight: Float=1) { t.setQ(bone,BodyMath.qlerp(t.q(bone),BodyMath.fromTo(t.q(bone).act(swing),p-t.p(bone))*t.q(bone),weight)) }
}

private final class BodySolver {
    typealias M = BodyMath
    let binding: SourceFullBodyBiped, transforms: BodyTransforms, iterations: Int, active: [Bool]
    let chains: [BodyChain], byBone: [Int:BodyNode], effects: [BodyEffector], poles: [Float3], globalWeight: Float
    var constraints: [BodyConstraint]=[], spineMaps: [BodyMap]=[], limbMaps: [[BodyMap]]=[], parentSwings: [Float3]=[]
    var headRotations: [simd_quatf]=[], endRotations: [simd_quatf]=[], pull=Float3.zero, zeroIterationOffset=Float3.zero
    init(binding: SourceFullBodyBiped, rig: RigDefinition, pose: RigPose, guides: [SourceStudioIK.Guide], active: [Bool], iterations: Int) throws {
        self.binding=binding;self.iterations=iterations;self.active=active;globalWeight=binding.settings.weight
        transforms=try BodyTransforms(rig:rig,pose:pose,required:binding.requiredBones)
        let initial=try BodyTransforms(rig:rig,pose:binding.initialPose,required:binding.requiredBones)
        chains=binding.chainBones.map { BodyChain($0.map { BodyNode($0,initial.p($0)) }) }
        let byBone=Dictionary(uniqueKeysWithValues:chains.flatMap(\.nodes).map { ($0.bone,$0) })
        self.byBone=byBone
        let globalWeight=binding.settings.weight
        let g=Dictionary(uniqueKeysWithValues:guides.map { ($0.targetID,$0) })
        let targetIDs: [Int32]=[0,1,4,7,10,3,6,9,12], groups=[0,4,3,2,1,4,3,2,1]
        effects=(0..<9).map { i in
            let s=binding.settings.effectors[i]
            return BodyEffector(node:byBone[binding.effectorBones[i]]!,children:binding.effectorChildren[i].map { byBone[$0]! },plane:binding.effectorPlanes[i].map { byBone[$0]! },guide:g[targetIDs[i]]!,weight:active[groups[i]] ? globalWeight:0,relative:s.maintainRelativePositionWeight,effectChildren:s.effectChildNodes)
        }
        poles=[2,5,8,11].map { UnityCoordinates.position(g[Int32($0)]!.position) }
        for i in 1...4 {
            let c=chains[i],n=c.nodes
            let direction=M.ortho(n[1].p-n[0].p,M.ortho(n[2].p-n[0].p,n[1].p-n[0].p))
            c.direction=direction;c.defaultDirection=initial.q(n[0].bone).inverse.act(direction)
            c.defaultChild=initial.q(n[2].bone).inverse.act(simd_cross(M.normalized(n[2].p-n[0].p),direction))
            if let parent=binding.shoulderParents[i-1] { parentSwings.append(initial.q(parent).inverse.act(initial.p(n[0].bone)-initial.p(parent))) }
            else { parentSwings.append(.zero) }
        }
        try lengths(initial)
    }
    func lengths(_ t: BodyTransforms) throws {
        for (i,c) in chains.enumerated() {
            c.length=0
            for j in 0..<(c.nodes.count-1) {
                let length=simd_distance(t.p(c.nodes[j].bone),t.p(c.nodes[j+1].bone))
                guard length>1e-7,length.isFinite else { throw RigError.invalid("Full-body IK contains a zero-length or nonfinite segment.") }
                c.nodes[j].length=length;c.length+=length
            }
            if i>0 { c.rootLength=simd_distance(t.p(c.nodes[0].bone),t.p(chains[0].nodes[0].bone)) }
        }
    }
    func solve(root: Int, vertical: Float, horizontal: Float) throws {
        if globalWeight<=0 { return }
        // SetToTarget has already sampled the guide values. PullBody precedes
        // LimitBend/ReadPose, and therefore uses initialized segment lengths.
        if iterations>0 && (vertical != 0 || horizontal != 0) {
            func contribution(_ e: BodyEffector,_ c: BodyChain,_ offset: Float3) -> Float3 {
                let d=e.target-(transforms.p(c.nodes[0].bone)+offset),length=simd_length(d)
                return length<c.length || length==0 ? .zero:d/length*(length-c.length)
            }
            var offset=contribution(effects[5],chains[1],.zero)*(active[4] ? 1:0)
            offset+=contribution(effects[6],chains[2],offset)*(active[3] ? 1:0)
            let up=transforms.q(root).act(Float3(0,1,0)),horizontalAxis=M.ortho(up,offset)
            pull=up*simd_dot(offset,up)*vertical+horizontalAxis*simd_dot(offset,horizontalAxis)*horizontal
        }
        for i in 1...4 { limitBend(i) }
        for e in effects {
            e.node.posWeight=e.weight;e.node.rotWeight=e.weight;e.node.q=e.rotation
            let offset=e === effects[0] ? pull*globalWeight:.zero
            e.node.offset+=offset
            if e.effectChildren && iterations>0 {
                e.childPositions=e.children.map { transforms.p($0.bone)-transforms.p(e.node.bone) }
                for n in e.children { n.offset+=offset }
            } else { e.childPositions=e.children.map { _ in .zero } }
            if !e.plane.isEmpty && e.relative>0 { e.animatedPlane=M.look(transforms.p(e.plane[1].bone)-transforms.p(e.plane[0].bone),transforms.p(e.plane[2].bone)-transforms.p(e.plane[0].bone)) }
            e.animated=transforms.p(e.node.bone)+e.node.offset
        }
        for c in chains { for n in c.nodes { n.p=transforms.p(n.bone)+n.offset } }
        try lengths(transforms)
        for (i,c) in chains.enumerated() {
            let s=binding.settings.chains[i]
            if iterations>0 {
                c.crossFades=s.children.map { chains[$0].nodes[0].posWeight*binding.settings.chains[$0].pull }
                let sum=max(1,c.nodes.last!.posWeight+c.crossFades.reduce(0,+))
                c.crossFades=c.crossFades.map { $0/sum }
                c.pullSum=max(1,s.children.reduce(Float(0)) { $0+binding.settings.chains[$1].pull })
                c.reachForce=c.nodes.count==3 ? s.reach*M.clamp(c.nodes[2].posWeight):0
                c.distance=simd_distance(transforms.p(c.nodes[0].bone),transforms.p(c.nodes.last!.bone))
            }
        }
        for (i,pair) in binding.constraints[0].enumerated() {
            let source=binding.settings.chains[0].constraints[i]
            let push=i<2 ? M.clamp(1-binding.settings.spineStiffness):source.pushElasticity
            let rigid=push<=0 && source.pullElasticity<=0
            constraints.append(.init(a:pair.0,b:pair.1,distance:simd_distance(transforms.p(chains[pair.0].nodes[0].bone),transforms.p(chains[pair.1].nodes[0].bone)),push:push,pull:source.pullElasticity,cross:rigid ? 1-(0.5+(binding.settings.chains[pair.0].pull-binding.settings.chains[pair.1].pull)*0.5):0.5))
        }
        readMappings()
        for _ in 0..<iterations {
            for e in effects where !e.plane.isEmpty { update(e) }
            _=pushChain(0);reach(0)
            for e in effects where e.plane.isEmpty { update(e) }
            trig(final:false);stage1(0)
            for e in effects where e.plane.isEmpty { update(e) }
            stage2(0,chains[0].nodes[0].p)
        }
        for e in effects where !e.plane.isEmpty { update(e) }
        if iterations==0 {
            // The source zero-iteration branch deliberately uses unscaled body
            // positionWeight here; global weight is applied by the mapping stage.
            zeroIterationOffset=M.lerp(pull,effects[0].target-(transforms.p(effects[0].node.bone)+pull),active[0] ? 1:0)
            for c in chains { c.nodes[0].p+=zeroIterationOffset }
        }
        trig(final:true)
        if iterations>0 { writeSpine(); for (i,bone) in binding.headBones.enumerated() { transforms.setQ(bone,M.qlerp(transforms.q(bone),headRotations[i],globalWeight*binding.settings.bones[i].maintainRotationWeight)) } }
        else { transforms.setP(binding.spine[0],transforms.p(binding.spine[0])+zeroIterationOffset) }
        for i in 0..<4 where active[[4,3,2,1][i]] {
            if iterations>0,let parent=binding.shoulderParents[i] {
                let q=transforms.q(parent),target=chains[i+1].nodes[0].p-transforms.p(parent)
                transforms.setQ(parent,M.fromTo(q.act(parentSwings[i]),target)*q)
            }
            limbMaps[i][0].writeRotation(transforms);limbMaps[i][1].writeRotation(transforms)
            let end=chains[i+1].nodes[2],mw=binding.settings.limbs[i].maintainRotationWeight*globalWeight
            if mw>0 { transforms.setQ(end.bone,M.qlerp(transforms.q(end.bone),endRotations[i],mw)) }
            if end.rotWeight>0 { transforms.setQ(end.bone,M.qlerp(transforms.q(end.bone),end.q,end.rotWeight)) }
        }
    }
    func limitBend(_ i: Int) {
        let c=chains[i],n=c.nodes,a=n[0].bone,b=n[1].bone,end=n[2].bone
        let normal=transforms.q(a).act(-c.defaultDirection),from=transforms.p(end)-transforms.p(b)
        let angleDenom=sqrt(simd_length_squared(normal)*simd_length_squared(from))
        let angle=angleDenom<1e-15 ? 0:acos(M.clamp(simd_dot(normal,from)/angleDenom,-1,1))*180 / Float.pi
        let availability=1-angle/180,clampWeight:Float=0.505*globalWeight
        let changed=availability<=clampWeight
        let saved=transforms.q(end)
        if changed {
            let a=M.clamp(1-(clampWeight-availability)/(1-availability)),bWeight=M.clamp(availability/clampWeight)
            let to=M.slerp(normal,from,a*bWeight)
            transforms.setQ(b,M.fromTo(from,to)*transforms.q(b))
        }
        let positionWeight=active[[4,3,2,1][i-1]] ? Float(1):0
        if positionWeight>0 {
            let tangent=M.ortho(transforms.p(b)-transforms.p(a),transforms.p(end)-transforms.p(b))
            let q=transforms.q(b)
            transforms.setQ(b,M.qlerp(q,M.fromTo(tangent,normal)*q,positionWeight*globalWeight))
        }
        if changed || positionWeight>0 { transforms.setQ(end,saved) }
    }
    func update(_ e: BodyEffector) {
        var position=e.node.p;e.planeOffset = .identity
        if !e.plane.isEmpty {
            position=e.animated
            if e.relative>0 {
                let p=e.plane
                let plane=M.look(p[1].p-p[0].p,p[2].p-p[0].p)*e.animatedPlane.inverse
                let relative=p[0].p+plane.act(transforms.p(e.node.bone)-transforms.p(p[0].bone))
                position=M.lerp(e.animated,relative+e.node.offset,e.relative)
                e.planeOffset=M.qlerp(.identity,plane,e.relative)
            }
        }
        e.node.p=M.lerp(position,e.target,e.weight)
        if e.effectChildren { for (i,n) in e.children.enumerated() { n.p=M.lerp(n.p,e.node.p+e.childPositions[i],e.weight) } }
    }
    func smooth(_ x: Float,_ mode: Int) -> Float { mode==1 ? x*x:mode==2 ? x*x*x:x }
    func pushChain(_ i: Int) -> Float3 {
        let c=chains[i],s=binding.settings.chains[i]
        var offset=Float3.zero
        for child in s.children { offset+=pushChain(child)*binding.settings.chains[child].pushParent }
        c.nodes.last!.p+=offset
        guard c.nodes.count==3,s.push>0 else { return .zero }
        let delta=c.nodes[2].p-c.nodes[0].p,length=simd_length(delta)
        guard length>0,c.distance>0 else { return .zero }
        let amount=1-length/c.distance
        guard amount>0 else { return .zero }
        let result = -delta*smooth(amount,s.pushSmoothing)*s.push
        c.nodes[0].p+=result;return result
    }
    func reach(_ i: Int) {
        let c=chains[i],s=binding.settings.chains[i]
        for child in s.children { reach(child) }
        guard c.reachForce>0 else { return }
        let d=c.nodes[2].p-c.nodes[0].p
        guard !M.equal(d,.zero) else { return }
        let length=simd_length(d),v=d/length*c.length
        let amount=M.clamp(M.clamp(length/c.length,1-c.reachForce,1+c.reachForce)-1+c.reachForce,-1,1)
        let shift=v*M.clamp(smooth(amount,s.reachSmoothing),0,length)
        c.nodes[0].p+=shift*(1-c.nodes[0].posWeight);c.nodes[2].p+=shift
    }
    func trig(final: Bool) {
        for i in 1...4 {
            let c=chains[i],n=c.nodes,d=n[2].p-n[0].p,distance=simd_length(d)
            if distance==0 { continue }
            let length=M.clamp(distance,0,c.length*0.99999),direction=d/distance*length
            var bend=n[1].p-n[0].p
            if final {
                let goal=poles[i-1]-n[0].p
                if !M.equal(goal,.zero) { c.direction=goal }
                let weight=globalWeight // InitIKTarget sets all pole weights to one.
                if weight>=1 { bend=M.normalized(c.direction) }
                else {
                    bend=M.fromTo(transforms.p(n[2].bone)-transforms.p(n[0].bone),d).act(transforms.p(n[1].bone)-transforms.p(n[0].bone))
                    if n[2].rotWeight>0 { bend=M.lerp(bend,-simd_cross(d,n[2].q.act(c.defaultChild)),n[2].rotWeight) }
                    if iterations>0 { let offset=effects[i+4].planeOffset;bend=(M.fromTo(offset.act(d),d)*offset).act(bend) }
                    bend=M.lerp(bend,M.normalized(c.direction),weight)
                }
            }
            let along=(length*length+n[0].length*n[0].length-n[1].length*n[1].length)/2/length
            let height=sqrt(max(0,n[0].length*n[0].length-along*along))
            n[1].p=n[0].p+(M.equal(direction,.zero) ? .zero:M.look(direction,bend).act(Float3(0,height,along)))
        }
    }
    func solveChildren() {
        for c in constraints {
            if c.push>=1 && c.pull>=1 { continue }
            let a=chains[c.a].nodes[0],b=chains[c.b].nodes[0],delta=b.p-a.p,length=simd_length(delta)
            if length==0 || length==c.distance { continue }
            let elasticity=length>c.distance ? c.pull:c.push
            let shift=delta*((1-c.distance/length)*(1-elasticity))
            a.p+=shift*c.cross;b.p-=shift*(1-c.cross)
        }
    }
    func forward(_ c: BodyChain,_ position: Float3) {
        c.nodes.last!.p=position
        if c.nodes.count>1 { for j in stride(from:c.nodes.count-2,through:0,by:-1) { c.nodes[j].p=M.joint(c.nodes[j].p,c.nodes[j+1].p,c.nodes[j].length) } }
    }
    func stage1(_ i: Int) {
        let c=chains[i],s=binding.settings.chains[i]
        for child in s.children { stage1(child) }
        if s.children.isEmpty { forward(c,c.nodes.last!.p);return }
        var result=c.nodes.last!.p
        solveChildren()
        for child in s.children {
            let childChain=chains[child],p=childChain.nodes[0].p
            let target=childChain.rootLength>0 ? M.joint(c.nodes.last!.p,p,childChain.rootLength):p
            result+=(target-c.nodes.last!.p)*(binding.settings.chains[child].pull/c.pullSum)
        }
        forward(c,M.lerp(result,c.nodes.last!.p,s.pin))
    }
    func stage2(_ i: Int,_ position: Float3) {
        let c=chains[i],s=binding.settings.chains[i]
        c.nodes[0].p=c.rootLength>0 ? M.joint(c.nodes[0].p,position,c.rootLength):position
        if c.nodes.count>1 { for j in 1..<c.nodes.count { c.nodes[j].p=M.joint(c.nodes[j].p,c.nodes[j-1].p,c.nodes[j-1].length) } }
        if !s.constraints.isEmpty {
            for _ in 0..<min(4,max(2,iterations)) {
                solveChildren()
                for (j,child) in s.children.enumerated() {
                    let a=c.nodes.last!,b=chains[child].nodes[0],delta=b.p-a.p,length=simd_length(delta)
                    if length==0 || length==chains[child].rootLength { continue }
                    let shift=delta*(1-chains[child].rootLength/length),cross=c.crossFades[j]
                    a.p+=shift*cross;b.p-=shift*(1-cross)
                }
            }
        }
        for child in s.children { stage2(child,c.nodes.last!.p) }
    }
    func readMappings() {
        let arms=chains[1].nodes[0].bone,otherArm=chains[2].nodes[0].bone,body=chains[0].nodes[0]
        spineMaps=binding.spine.map { BodyMap(bone:$0,plane:[]) }
        spineMaps[0]=BodyMap(bone:binding.spine[0],plane:[body,chains[3].nodes[0],chains[4].nodes[0]])
        spineMaps[spineMaps.count-1]=BodyMap(bone:binding.spine.last!,plane:[body,chains[1].nodes[0],chains[2].nodes[0]])
        if iterations>0 {
            spineMaps[0].read(transforms);spineMaps[spineMaps.count-1].read(transforms)
            for i in 0..<(spineMaps.count-1) {
                let bone=spineMaps[i].bone,next=spineMaps[i+1].bone,delta=transforms.p(next)-transforms.p(bone)
                spineMaps[i].length=simd_length(delta)
                spineMaps[i].swing=transforms.q(bone).inverse.act(delta)
                spineMaps[i].twist=transforms.q(bone).inverse.act(M.ortho(delta,transforms.p(arms)-transforms.p(otherArm)))
            }
            headRotations=binding.headBones.map { transforms.q($0) }
        }
        for i in 1...4 {
            let n=chains[i].nodes
            var a=BodyMap(bone:n[0].bone,plane:[n[0],n[1],n[2]]),b=BodyMap(bone:n[1].bone,plane:[n[1],n[2],n[0]])
            a.read(transforms);b.read(transforms,position:false);limbMaps.append([a,b]);endRotations.append(transforms.q(n[2].bone))
        }
    }
    func writeSpine() {
        let last=spineMaps.count-1,rootIndex=binding.spine.firstIndex(of:chains[0].nodes[0].bone)!
        let firstPoint=spineMaps[0].planePoint(),lastPoint=spineMaps[last].planePoint(),rootPoint=chains[0].nodes[0].p
        if spineMaps.count>3 || rootIndex != 1 {
            let offset=rootPoint-transforms.p(spineMaps[rootIndex].bone)
            for i in spineMaps.indices { spineMaps[i].ik=transforms.p(spineMaps[i].bone)+offset }
            for _ in 0..<binding.settings.spine.iterations {
                spineMaps[last].ik=lastPoint
                for i in stride(from:last-1,through:0,by:-1) { spineMaps[i].ik=M.joint(spineMaps[i].ik,spineMaps[i+1].ik,spineMaps[i].length) }
                spineMaps[0].ik=firstPoint
                for i in 1...last { spineMaps[i].ik=M.joint(spineMaps[i].ik,spineMaps[i-1].ik,spineMaps[i-1].length) }
                spineMaps[rootIndex].ik=rootPoint
            }
        } else { spineMaps[0].ik=firstPoint;spineMaps[rootIndex].ik=rootPoint }
        spineMaps[last].ik=lastPoint
        transforms.setP(spineMaps[0].bone,spineMaps[0].ik);spineMaps[0].writeRotation(transforms)
        for i in 1..<last {
            let map=spineMaps[i],next=spineMaps[i+1].ik
            map.swingTo(next,transforms)
            if active[0] {
                let twist=M.ortho(next-transforms.p(map.bone),chains[1].nodes[0].p-chains[2].nodes[0].p),q=transforms.q(map.bone)
                transforms.setQ(map.bone,M.qlerp(q,M.fromTo(q.act(map.twist),twist)*q,Float(i)/Float(spineMaps.count-2)))
            }
        }
        transforms.setP(spineMaps[last].bone,spineMaps[last].ik);spineMaps[last].writeRotation(transforms)
    }
}
