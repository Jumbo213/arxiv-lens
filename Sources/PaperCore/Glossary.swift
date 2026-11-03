import Foundation

public enum GlossaryCatalog {
    public struct Term: Identifiable, Sendable {
        public let english: String
        public let chinese: String
        public var id: String { english }
    }

    public struct Section: Identifiable, Sendable {
        public let title: String
        public let terms: [Term]
        public var id: String { title }

        fileprivate init(_ title: String, _ entries: String) {
            self.title = title
            terms = entries.split(separator: "\n").compactMap { entry in
                let pair = entry.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                return pair.count == 2 ? Term(english: pair[0], chinese: pair[1]) : nil
            }
        }
    }

    public static let sections = [
        Section("机器学习", """
        supervised learning = 监督学习
        unsupervised learning = 无监督学习
        semi-supervised learning = 半监督学习
        self-supervised learning = 自监督学习
        representation learning = 表征学习
        contrastive learning = 对比学习
        transfer learning = 迁移学习
        reinforcement learning = 强化学习
        continual learning = 持续学习
        multi-task learning = 多任务学习
        active learning = 主动学习
        few-shot learning = 少样本学习
        zero-shot learning = 零样本学习
        zero-shot transfer = 零样本迁移
        distribution shift = 分布偏移
        covariate shift = 协变量偏移
        out-of-distribution = 分布外
        inductive bias = 归纳偏置
        generalization = 泛化
        sample efficiency = 样本效率
        data augmentation = 数据增强
        feature extraction = 特征提取
        feature embedding = 特征嵌入
        ablation study = 消融实验
        loss function = 损失函数
        cross-entropy = 交叉熵
        gradient descent = 梯度下降
        gradient clipping = 梯度裁剪
        learning rate = 学习率
        regularization = 正则化
        overfitting = 过拟合
        underfitting = 欠拟合
        model calibration = 模型校准
        uncertainty quantification = 不确定性量化
        latent space = 潜空间
        residual connection = 残差连接
        knowledge distillation = 知识蒸馏
        """),
        Section("大模型", """
        large language model = 大语言模型
        LLM = 大语言模型
        foundation model = 基础模型
        vision-language model = 视觉语言模型
        multimodal language model = 多模态语言模型
        language modeling = 语言建模
        sequence transduction = 序列转导
        encoder-decoder = 编码器–解码器
        autoregressive = 自回归
        attention mechanism = 注意力机制
        self-attention = 自注意力
        cross-attention = 交叉注意力
        multi-head attention = 多头注意力
        scaled dot-product attention = 缩放点积注意力
        position-wise feed-forward network = 逐位置前馈网络
        layer normalization = 层归一化
        positional encoding = 位置编码
        rotary positional embedding = 旋转位置嵌入
        RoPE = 旋转位置嵌入
        grouped-query attention = 分组查询注意力
        mixture of experts = 混合专家
        MoE = 混合专家
        expert routing = 专家路由
        context window = 上下文窗口
        context length = 上下文长度
        token = 词元
        tokenization = 词元化
        tokenizer = 词元化器
        pretraining = 预训练
        continued pretraining = 持续预训练
        scaling law = 缩放定律
        in-context learning = 上下文学习
        chain-of-thought = 思维链
        retrieval-augmented generation = 检索增强生成
        RAG = 检索增强生成
        KV cache = 键值缓存
        speculative decoding = 推测解码
        beam search = 束搜索
        instruction following = 指令遵循
        tool calling = 工具调用
        hallucination = 幻觉
        """),
        Section("后训练", """
        post-training = 后训练
        fine-tuning = 微调
        instruction tuning = 指令微调
        supervised fine-tuning = 监督微调
        SFT = 监督微调
        parameter-efficient fine-tuning = 参数高效微调
        PEFT = 参数高效微调
        low-rank adaptation = 低秩适配
        LoRA = 低秩适配
        alignment = 对齐
        preference data = 偏好数据
        preference pair = 偏好对
        preference optimization = 偏好优化
        direct preference optimization = 直接偏好优化
        DPO = 直接偏好优化
        reinforcement learning from human feedback = 基于人类反馈的强化学习
        RLHF = 基于人类反馈的强化学习
        reinforcement learning from AI feedback = 基于 AI 反馈的强化学习
        RLAIF = 基于 AI 反馈的强化学习
        reinforcement learning with verifiable rewards = 基于可验证奖励的强化学习
        RLVR = 基于可验证奖励的强化学习
        proximal policy optimization = 近端策略优化
        PPO = 近端策略优化
        group relative policy optimization = 组相对策略优化
        GRPO = 组相对策略优化
        policy gradient = 策略梯度
        reference policy = 参考策略
        on-policy = 同策略
        off-policy = 异策略
        reward model = 奖励模型
        reward shaping = 奖励塑形
        reward hacking = 奖励投机
        process reward model = 过程奖励模型
        outcome reward model = 结果奖励模型
        verifier = 验证器
        advantage estimation = 优势估计
        generalized advantage estimation = 广义优势估计
        importance sampling = 重要性采样
        rejection sampling = 拒绝采样
        rollout = 轨迹采样
        KL divergence = KL 散度
        value function = 价值函数
        reward signal = 奖励信号
        """),
        Section("神经符号", """
        neuro-symbolic = 神经符号
        neurosymbolic = 神经符号
        neural-symbolic = 神经符号
        neuro-symbolic reasoning = 神经符号推理
        symbolic reasoning = 符号推理
        symbolic representation = 符号表示
        differentiable reasoning = 可微推理
        differentiable logic = 可微逻辑
        logic tensor network = 逻辑张量网络
        first-order logic = 一阶逻辑
        propositional logic = 命题逻辑
        higher-order logic = 高阶逻辑
        probabilistic logic = 概率逻辑
        fuzzy logic = 模糊逻辑
        description logic = 描述逻辑
        logical entailment = 逻辑蕴涵
        logical inference = 逻辑推断
        forward chaining = 前向链推理
        backward chaining = 后向链推理
        abduction = 溯因推理
        deductive reasoning = 演绎推理
        inductive reasoning = 归纳推理
        inductive logic programming = 归纳逻辑编程
        logic programming = 逻辑编程
        probabilistic logic programming = 概率逻辑编程
        theorem proving = 定理证明
        automated theorem proving = 自动定理证明
        proof assistant = 证明助手
        proof search = 证明搜索
        formal verification = 形式化验证
        formal specification = 形式化规约
        autoformalization = 自动形式化
        satisfiability modulo theories = 可满足性模理论
        SMT solver = SMT 求解器
        constraint satisfaction = 约束满足
        program synthesis = 程序综合
        semantic parsing = 语义解析
        knowledge graph = 知识图谱
        entity linking = 实体链接
        rule induction = 规则归纳
        symbol grounding = 符号落地
        compositional generalization = 组合泛化
        """)
    ]

    private static let matchers = sections.flatMap(\.terms).sorted {
        if $0.english.count == $1.english.count { return $0.english < $1.english }
        return $0.english.count > $1.english.count
    }.compactMap { term -> (Term, NSRegularExpression)? in
        let word = NSRegularExpression.escapedPattern(for: term.english)
        let isAcronym = term.english.count <= 5 && term.english == term.english.uppercased()
        let options: NSRegularExpression.Options = isAcronym ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w])"# + word + #"(?:s|es)?(?![\w])"#, options: options)
        else { return nil }
        return (term, regex)
    }

    static func relevant(to text: String, custom: String) -> String {
        let overrides = Set(custom.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == "＝" }) else { return nil }
            return line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        })
        let search = text.replacingOccurrences(of: "[‐‑–—]", with: "-", options: .regularExpression)
        let range = NSRange(search.startIndex..<search.endIndex, in: search)
        return matchers.lazy.filter { term, regex in
            !overrides.contains(term.english.lowercased()) && regex.firstMatch(in: search, range: range) != nil
        }.prefix(35).map { "\($0.0.english) = \($0.0.chinese)" }.joined(separator: "\n")
    }
}
