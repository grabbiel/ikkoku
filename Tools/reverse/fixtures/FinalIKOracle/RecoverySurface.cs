// Unexecuted editor/setup surfaces needed to compile unchanged recovered solver classes.
using UnityEngine;
namespace RootMotion {
 public static class Warning { public delegate void Logger(string message);public static void Log(string message,Transform root=null,bool logInEditMode=false)=>throw new System.InvalidOperationException(message); }
 public static class Hierarchy { public static bool IsAncestor(Transform child,Transform ancestor)=>child.IsChildOf(ancestor); }
 public class BipedReferences { public Transform root,pelvis,leftThigh,leftCalf,leftFoot,rightThigh,rightCalf,rightFoot,leftUpperArm,leftForearm,leftHand,rightUpperArm,rightForearm,rightHand,head;public Transform[] spine=new Transform[0];public bool isFilled=>true; }
 public class BipedLimbOrientations {public class LimbOrientation {public Vector3 upperBoneForwardAxis,lowerBoneForwardAxis,lastBoneLeftAxis;}public LimbOrientation leftArm,rightArm,leftLeg,rightLeg;}
}
namespace RootMotion.FinalIK { public class RotationLimit:MonoBehaviour {} }
