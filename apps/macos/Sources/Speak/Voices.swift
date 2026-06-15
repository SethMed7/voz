/// Voice catalog: "system" = built-in macOS voice (zero setup); the rest are
/// Kokoro voice ids, used when the ~/.voz/kokoro helper is installed.
enum Voices {
    static let all: [(id: String, label: String)] = [
        ("system", "System voice"),
        ("af_heart", "Heart (US female)"),
        ("af_bella", "Bella (US female)"),
        ("af_nicole", "Nicole (US female)"),
        ("af_nova", "Nova (US female)"),
        ("af_sarah", "Sarah (US female)"),
        ("af_sky", "Sky (US female)"),
        ("am_adam", "Adam (US male)"),
        ("am_eric", "Eric (US male)"),
        ("am_liam", "Liam (US male)"),
        ("am_michael", "Michael (US male)"),
        ("am_onyx", "Onyx (US male)"),
        ("bf_alice", "Alice (UK female)"),
        ("bf_emma", "Emma (UK female)"),
        ("bf_isabella", "Isabella (UK female)"),
        ("bf_lily", "Lily (UK female)"),
        ("bm_daniel", "Daniel (UK male)"),
        ("bm_fable", "Fable (UK male)"),
        ("bm_george", "George (UK male)"),
        ("bm_lewis", "Lewis (UK male)"),
    ]

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? id
    }
}
