using UnityEngine;
using BepInEx;

[BepInPlugin("Ikkoku.Validation.MixedCase_é", "Native lifecycle fixture", "1.0.0")]
[BepInProcess("CharaStudio")]
public class LifecycleFixture : BaseUnityPlugin {
    public float publicValue = 1f;
    [SerializeField] private float serializedValue = 2f;
    [System.NonSerialized] public float transientValue = 3f;
    private float privateValue = 4f;
    public bool clone;
    public float starts;
    public float updates;
    public float lateUpdates;
    public float fixedUpdates;
    public float disables;
    public float destroys;
    public float copiedPrivate;
    void Awake() { copiedPrivate = privateValue; }
    void OnEnable() { }
    void Start() { starts += 1f; }
    void FixedUpdate() { fixedUpdates += 1f; }
    void Update() {
        updates += 1f;
        if (!clone) {
            publicValue = 21f; serializedValue = 41f; transientValue = 31f; privateValue = 51f;
            clone = true;
            GameObject copy = GameObject.Instantiate(gameObject);
            gameObject.SetActive(false);
        } else {
            GameObject.Destroy(gameObject);
        }
    }
    void LateUpdate() { lateUpdates += 1f; }
    void OnDisable() { disables += 1f; }
    void OnDestroy() { destroys += 1f; }
}
