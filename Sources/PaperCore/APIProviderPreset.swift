public struct APIProviderPreset: Identifiable, Sendable {
    public let name: String
    public let url: String
    public var id: String { url }

    public static let presets: [Self] = [
        .init(name: "DeepSeek", url: "https://api.deepseek.com/chat/completions"),
        .init(name: "OpenAI（ChatGPT 模型）", url: "https://api.openai.com/v1"),
        .init(name: "Google Gemini", url: "https://generativelanguage.googleapis.com/v1beta/openai"),
        .init(name: "通义千问（阿里云北京）", url: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(name: "Kimi（月之暗面中国站）", url: "https://api.moonshot.cn/v1"),
        .init(name: "智谱 GLM", url: "https://open.bigmodel.cn/api/paas/v4"),
        .init(name: "豆包（火山方舟）", url: "https://ark.cn-beijing.volces.com/api/v3"),
        .init(name: "OpenRouter", url: "https://openrouter.ai/api/v1"),
        .init(name: "Ollama（本机）", url: "http://127.0.0.1:11434/v1")
    ]
}
