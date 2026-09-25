using UnityEngine;
using BepInEx;

[BepInPlugin("Ikkoku.Validation.StudioMotion", "Studio motion fixture", "1.0.0")]
[BepInProcess("CharaStudio")]
public class StudioMotionFixture : BaseUnityPlugin {
    public float elapsed;
    public float starts;
    public float speed = .125f;
    void Awake() { }
    void Start() { starts += 1f; }
    void Update() {
        elapsed += Time.deltaTime;
        transform.Translate(new Vector3(speed * Time.deltaTime, 0f, 0f), Space.World);
    }
}
