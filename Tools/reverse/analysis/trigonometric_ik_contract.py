"""Independent matrix oracle for the recovered rigid, direct-chain IK kernel."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import numpy as np

REFLECTION = np.diag([1., 1., -1.])
ZERO_SQUARED = 9.99999944e-11


def normalize(v): return v / np.linalg.norm(v)


def look(forward, up):
    if np.dot(forward, forward) < ZERO_SQUARED or np.dot(up, up) < ZERO_SQUARED:
        raise ValueError("degenerate LookRotation")
    f = normalize(forward)
    right = np.cross(up, f)
    if np.dot(right, right) < ZERO_SQUARED: raise ValueError("degenerate LookRotation")
    r = normalize(right)
    return np.column_stack([r, np.cross(f, r), f])


def rotation(axis, angle):
    x, y, z = normalize(np.array(axis, dtype=float))
    skew = np.array([[0,-z,y],[z,0,-x],[-y,x,0]])
    return np.eye(3) + math.sin(angle)*skew + (1-math.cos(angle))*(skew@skew)


def interpolate_rotation(a, b, weight):
    relative = a.T @ b
    angle = math.acos(np.clip((np.trace(relative)-1)/2, -1, 1))
    if angle < 1e-10: return a
    axis = np.array([relative[2,1]-relative[1,2],relative[0,2]-relative[2,0],relative[1,0]-relative[0,1]])
    if np.linalg.norm(axis) < 1e-8:
        values,vectors=np.linalg.eigh((relative+relative.T)/2)
        axis=vectors[:,np.argmax(values)]
    return a @ rotation(axis, angle*weight)


def matrix_quaternion(matrix):
    # Eigenvector formulation is independent of simd's matrix/quaternion path.
    m = matrix
    k = np.array([
        [m[0,0]-m[1,1]-m[2,2],m[1,0]+m[0,1],m[2,0]+m[0,2],m[2,1]-m[1,2]],
        [m[1,0]+m[0,1],m[1,1]-m[0,0]-m[2,2],m[2,1]+m[1,2],m[0,2]-m[2,0]],
        [m[2,0]+m[0,2],m[2,1]+m[1,2],m[2,2]-m[0,0]-m[1,1],m[1,0]-m[0,1]],
        [m[2,1]-m[1,2],m[0,2]-m[2,0],m[1,0]-m[0,1],np.trace(m)]])/3
    values,vectors=np.linalg.eigh(k)
    q=vectors[:,np.argmax(values)]
    return q if q[3] >= 0 else -q


class MatrixSolver:
    def __init__(self, bind_positions, bind_rotations, normal):
        self.normal=np.array(normal,dtype=float)
        if np.dot(self.normal,self.normal)<ZERO_SQUARED:self.normal=np.array([1.,0,0])
        self.offsets=[look(bind_positions[i+1]-bind_positions[i],self.normal).T @ bind_rotations[i] for i in range(2)]
        self.local_normals=[r.T @ self.normal for r in bind_rotations[:2]]
        self.set_plane(bind_positions)

    def set_plane(self, positions):
        n=np.cross(positions[1]-positions[0],positions[2]-positions[1])
        if np.dot(n,n)>=ZERO_SQUARED:self.normal=n

    def set_goal(self, positions, goal, target, weight):
        if weight<=0:return
        n=np.cross(goal-positions[0],target-positions[0])
        if np.dot(n,n)>=ZERO_SQUARED:self.normal=n if weight>=1 else self.normal+(n-self.normal)*weight

    def solve(self, positions, rotations, target, target_rotation, position_weight, rotation_weight):
        p=np.array(positions,copy=True);r=np.array(rotations,copy=True)
        w=np.clip(position_weight,0,1);rw=np.clip(rotation_weight,0,1)
        if w>0:
            first=np.dot(p[1]-p[0],p[1]-p[0]);second=np.dot(p[2]-p[1],p[2]-p[1])
            target=p[2]+(target-p[2])*w
            normal=r[0]@self.local_normals[0]+(self.normal-r[0]@self.local_normals[0])*w
            direction=target-p[0]
            if np.dot(direction,direction)<ZERO_SQUARED:bend=np.zeros(3)
            else:
                distance=np.linalg.norm(direction)
                along=(distance*distance+first-second)/2/distance
                height=math.sqrt(max(0,first-along*along))
                bend=look(direction,np.cross(direction,normal))@np.array([0,height,along])
            first_direction=(p[1]-p[0])+(bend-(p[1]-p[0]))*w
            if np.dot(first_direction,first_direction)<ZERO_SQUARED:first_direction=p[1]-p[0]
            result=look(first_direction,normal)@self.offsets[0]
            delta=result@r[0].T
            p[1:]=p[0]+(delta@(p[1:]-p[0]).T).T
            r[1:]=np.array([delta@q for q in r[1:]])
            r[0]=result
            result=look(target-p[1],r[1]@self.local_normals[1])@self.offsets[1]
            delta=result@r[1].T
            p[2]=p[1]+delta@(p[2]-p[1]);r[2]=delta@r[2];r[1]=result
        if rw>0:r[2]=interpolate_rotation(r[2],target_rotation,rw)
        return p,r


def native_pose(positions,rotations):
    return dict(positions=(REFLECTION@positions.T).T.tolist(),
                rotations=[matrix_quaternion(REFLECTION@r@REFLECTION).tolist() for r in rotations])


def fixtures():
    cases=[]
    bind=np.array([[0,0,0],[0,1,0],[.5,1.8,.1]],dtype=float)
    rotations=np.array([rotation([0,1,0],.2),rotation([1,0,0],-.3),rotation([0,0,1],.4)])
    target=np.array([.8,1.3,.45]);target_rotation=rotation([1,2,3],.8)
    variants=[]
    variants.append(("rest",bind.copy(),rotations.copy(),target))
    delta=rotation([0,0,1],.3);translation=np.array([.3,-.2,1.])
    animated=translation+(delta@bind.T).T
    animated_rotations=np.array([delta@q for q in rotations])
    variants.append(("animated",animated,animated_rotations,translation+np.array([.7,1.1,.3])))
    variants.append(("unreachable",bind.copy(),rotations.copy(),np.array([4,3,1.])))

    def add(name,p,r,t,w,rw,goal_weight=None,set_plane=False):
        solver=MatrixSolver(bind,rotations,[1,0,0]);goal=np.array([-1.,.8,.7])
        if set_plane:solver.set_plane(p)
        if goal_weight is not None:solver.set_goal(p,goal,t,goal_weight)
        result,orientation=solver.solve(p,r,t,target_rotation,w,rw)
        cases.append(dict(name=name,bindPose=native_pose(bind,rotations),pose=native_pose(p,r),
                          initialBendNormal=[-1.,0,0],bendGoal=None if goal_weight is None else dict(position=(REFLECTION@goal).tolist(),weight=goal_weight),
                          setBendPlaneToCurrent=set_plane,targetPosition=(REFLECTION@t).tolist(),targetRotation=matrix_quaternion(REFLECTION@target_rotation@REFLECTION).tolist(),
                          positionWeight=w,rotationWeight=rw,expectedBendNormal=(-REFLECTION@solver.normal).tolist(),
                          expectedPositions=(REFLECTION@result.T).T.tolist(),expectedRotations=[(REFLECTION@q@REFLECTION).tolist() for q in orientation]))
    for name,p,r,t in variants:
        for w in [-.25,0,.25,.5,1,1.25]:
            for rw in [0,.4,1]:add(f"{name}-{w}-{rw}",p,r,t,w,rw)
    for weight in [0,.3,1,2]:add(f"bend-goal-{weight}",bind,rotations,target,1,.5,goal_weight=weight)
    add("updated-plane",variants[1][1],variants[1][2],variants[1][3],.7,.2,set_plane=True)
    add("target-at-root",bind,rotations,bind[0],1,0)
    return cases


def evidence(index):
    assemblies=json.loads(Path(index).read_text())["assemblies"]
    assembly=next(a for a in assemblies if "Koikatu_Data/Managed/Assembly-CSharp-firstpass.dll" in a["sourcePaths"])
    directory=Path(assembly["directory"]);manifest=json.loads((directory/"manifest.json").read_text())
    overrides={x["type"]:x["file"] for x in manifest.get("typeOverrides",[])}
    result=[]
    for name in ["RootMotion.FinalIK.IKSolverTrigonometric","RootMotion.QuaTools"]:
        ns,_,last=name.rpartition(".")
        path=directory/overrides[name] if name in overrides else directory/assembly["selectedProject"]/ns/(last+".cs")
        text=path.read_text()
        if "Error decompiling" in text:raise ValueError("Unresolved solver source")
        result.append(dict(type=name,path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    return dict(assemblySHA256=assembly["assemblySHA256"],files=result)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--recovery-index",type=Path,required=True);parser.add_argument("--output",type=Path,required=True);args=parser.parse_args()
    result=dict(schemaVersion=1,coordinateSpace="native-right-handed-y-up",scope="rigid direct three-transform chain",sourceEvidence=evidence(args.recovery_index),cases=fixtures())
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps(dict(cases=len(result["cases"]),output=str(args.output))))


if __name__=="__main__":main()
