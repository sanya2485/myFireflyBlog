<script lang="ts">
  import { onMount } from "svelte";
  import Icon from "@components/common/Icon.svelte";

  /**
   * AgentChat.svelte — 博客 AI 助手自建聊天窗（M3 双 agent 壳）
   *
   * 取代原 Coze Web SDK 聊天窗（SDK 不透传 function_call/tool_response，
   * 拿不到「对暗号」换取的每日 JWT）。自建壳：
   * - 双 agent 并行常驻：Coze 博客助手 + Dify 智库，点击切换（D2 指针切换）
   * - Coze 侧：浏览器持 Coze access_token 直连 api.coze.cn/v3/chat（stream, auto_save_history:false），
   *   从 SSE 的 tool_response 解析每日 JWT（D1/D4）
   * - Dify 侧：带 Authorization: Bearer <每日JWT> 调后端 /api/coze/dify/chat（M4 代理，D7）
   * - 大闸门：无有效每日 JWT → Dify 锁定态（D8）
   * - 会话持久化：agentchat_ 前缀 localStorage（避开 clearCozeSessionCache 的 coze_ 清理范围）
   *
   * 本组件 client:load 挂载于 CozeChat.astro（Layout.astro body 尾部，#swup-container 之外），
   * 跨页存活；悬浮球 + 问候气泡的静态壳和 CSS 保留在 CozeChat.astro。
   */

  interface Props {
    botId: string;
    apiBase: string;
    cozeApiBase: string;
  }
  let { botId, apiBase, cozeApiBase }: Props = $props();

  // ==================== 类型 ====================
  type AgentKey = "coze" | "dify";
  interface ChatMessage {
    role: "user" | "assistant";
    content: string;
    ts: number;
    quote?: string; // 追问引用：本条消息引用了哪条回复（「追问」携带，历史注入用）
  }
  interface AgentState {
    messages: ChatMessage[];
    conversationId?: string; // Dify 侧会话 id
    streaming: boolean;
    followUps: string[]; // Coze 回复后追问建议（follow_up 事件，session-only 不持久化）
  }
  interface AuthState {
    token?: string;
    expiresAt?: number; // 毫秒时间戳
  }
  type ToastType = "success" | "error" | "warning";

  // ==================== 常量 ====================
  // 问候气泡「不再显示」标记（与旧版一致）；agentchat_ 前缀避开 clearCozeSessionCache 的 coze_ 清理
  const GREETING_KEY = "coze_greeting_off";
  const LS_AUTH = "agentchat_auth";
  const LS_ACTIVE = "agentchat_active";
  const LS_DIFY_CONV = "agentchat_dify_conv";
  const lsMsg = (k: AgentKey) => `agentchat_messages_${k}`;

  // ==================== 状态 ====================
  let panelOpen = $state(false);
  let activeAgent: AgentKey = $state("coze");
  let agents = $state<Record<AgentKey, AgentState>>({
    coze: { messages: [], streaming: false, followUps: [] },
    dify: { messages: [], streaming: false, followUps: [] },
  });
  let auth = $state<AuthState>({});
  let input = $state("");
  let cozeToken = $state<string | null>(null);
  // 开场白（bot info 的 onboarding_info）：空会话时渲染为首条消息；session-only 不持久化
  let cozePrologue = $state<string | null>(null);
  let cozeSuggested = $state<string[]>([]);
  let prologueFetched = false;
  let toast = $state<{ text: string; type: ToastType } | null>(null);
  let msgBox = $state<HTMLElement | null>(null);
  let textInput = $state<HTMLTextAreaElement | null>(null);
  // 移动端软键盘抬升（#10）：updateKbLift() 依 visualViewport 置位/复位
  let kbUp = $state(false);
  // 追问引用条（仅 Coze）：「追问」点击后挂在输入框上方，发送时随消息携带
  let cozeQuote = $state<ChatMessage | null>(null);

  // 访客 ID（浏览器持久化；SSR 下为空，onMount 后赋值）
  let visitorId = "";
  let toastTimer: ReturnType<typeof setTimeout> | undefined;
  let swupBound = false;

  // 时钟节拍：$derived 只在依赖变化时重算，若仅读 Date.now() 不会随时间重跑；
  // 用 30s 节拍驱动，让每日 JWT 在午夜过期后 UI 锁屏自动翻转（后端仍硬校验兜底）
  let now = $state(Date.now());

  // 大闸门：有 token 且未过期（每日 JWT 次日 00:00 失效）
  let isAuthValid = $derived(
    !!(auth.token && auth.expiresAt && auth.expiresAt > now),
  );

  // ==================== localStorage（SSR 安全：全部经函数访问） ====================
  function getLS(key: string): string | null {
    if (typeof localStorage === "undefined") return null;
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  }
  function setLS(key: string, value: string) {
    if (typeof localStorage === "undefined") return;
    try {
      localStorage.setItem(key, value);
    } catch {
      /* 隐私模式等场景静默失败 */
    }
  }
  function removeLS(key: string) {
    if (typeof localStorage === "undefined") return;
    try {
      localStorage.removeItem(key);
    } catch {
      /* noop */
    }
  }

  function saveAuth() {
    setLS(LS_AUTH, JSON.stringify(auth));
  }
  function saveActive() {
    setLS(LS_ACTIVE, activeAgent);
  }
  function saveMessages(k: AgentKey) {
    setLS(lsMsg(k), JSON.stringify(agents[k].messages));
  }
  function saveDifyConv() {
    if (agents.dify.conversationId) {
      setLS(LS_DIFY_CONV, agents.dify.conversationId);
    } else {
      removeLS(LS_DIFY_CONV);
    }
  }

  /** 修复持久化历史（自愈）：历史永远只含「问答成对」的完整轮次——
      去掉空内容消息（空 user 无意义；空 assistant = 未完成占位），
      再去掉尾部没收到回复的 user 轮次（刷新 / 流中断残留）。否则残留的
      未完成轮次会让下一轮 history 出现 [.., user, user] / 尾 user，破坏交替 → 卡会话 */
  function normalizeMessages(msgs: ChatMessage[]): ChatMessage[] {
    const out = msgs.filter((m) => m.content.trim().length > 0);
    while (out.length && out[out.length - 1].role === "user") out.pop();
    return out;
  }

  function loadPersisted() {
    try {
      const a = getLS(LS_AUTH);
      if (a) auth = { ...auth, ...JSON.parse(a) };
      const cm = getLS(lsMsg("coze"));
      if (cm) agents.coze.messages = normalizeMessages(JSON.parse(cm));
      const dm = getLS(lsMsg("dify"));
      if (dm) agents.dify.messages = normalizeMessages(JSON.parse(dm));
      const dv = getLS(LS_DIFY_CONV);
      if (dv) agents.dify.conversationId = dv;
      const act = getLS(LS_ACTIVE);
      if (act === "coze" || act === "dify") activeAgent = act;
    } catch {
      /* 旧数据损坏则忽略，重新开始 */
    }
  }

  // ==================== Toast ====================
  function showToast(text: string, type: ToastType = "warning") {
    toast = { text, type };
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast = null), 4500);
  }

  // ==================== 悬浮球 + 问候气泡 ====================
  function closeGreeting() {
    document.getElementById("coze-bubble")?.classList.remove("coze-bubble-show");
    document.getElementById("coze-widget")?.classList.remove("coze-has-bubble");
  }

  function maybeShowGreeting() {
    if (getLS(GREETING_KEY)) return; // 已点「不再显示」
    const bubble = document.getElementById("coze-bubble");
    const w = document.getElementById("coze-widget");
    if (!bubble || !w) return;
    bubble.classList.add("coze-bubble-show");
    w.classList.add("coze-has-bubble");

    const timer = setTimeout(closeGreeting, 3000);
    const closeBtn = document.getElementById("coze-bubble-close");
    closeBtn?.addEventListener("click", () => {
      clearTimeout(timer);
      closeGreeting();
    });
    const neverBtn = document.getElementById("coze-bubble-never");
    neverBtn?.addEventListener("click", () => {
      clearTimeout(timer);
      setLS(GREETING_KEY, "1"); // 「不再显示」永久停用
      closeGreeting();
    });
  }

  // 清理旧版 SDK 残留的 coze_ 会话缓存（白名单：visitorId + 问候标记）
  function clearLegacyCozeCache() {
    if (typeof localStorage === "undefined") return;
    const keysToRemove: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key && (key.startsWith("coze_") || key.startsWith("COZE_"))) {
        keysToRemove.push(key);
      }
    }
    keysToRemove
      .filter((k) => k !== "coze_visitor_id" && k !== GREETING_KEY)
      .forEach((k) => removeLS(k));
  }

  // ==================== 面板开关 ====================
  function openPanel() {
    panelOpen = true;
    closeGreeting();
    document.getElementById("coze-widget")?.classList.add("coze-chat-open");
    void fetchBotInfo(); // 挂载时没拉到开场白（如 token 初始化失败）则开面板重试
    // 聚焦输入框（等待面板渲染完成）
    requestAnimationFrame(() => textInput?.focus());
  }
  function closePanel() {
    panelOpen = false;
    // 收起面板必须同步让出焦点：textarea 若仍持焦，面板隐藏(visibility)期间光标
    // 可能残留在不可见区域造成「非输入处冒出 | 光标」的伪影；blur 后光标只在真正聚焦的输入框出现
    textInput?.blur();
    document.getElementById("coze-widget")?.classList.remove("coze-chat-open");
  }

  function bindBall() {
    // 点击判定绑在不移动的 hitbox 上（球是其子元素，点击会冒泡）
    const zone = document.getElementById("coze-hitbox") || document.getElementById("coze-ball");
    if (!zone) return;
    zone.addEventListener("click", () => {
      if (panelOpen) closePanel();
      else openPanel();
    });
  }

  // ==================== agent 切换 ====================
  function switchAgent(k: AgentKey) {
    if (k === activeAgent) return;
    activeAgent = k;
    saveActive();
    // 锁定态切到 dify：面板内展示「大闸门锁屏」（.dify-lock）。#12 起不再弹
    // 右下角「dify 未解锁」toast —— 那个浮动弹窗正是用户要求去掉的。
  }

  // ==================== Coze access token ====================
  async function fetchToken(endpoint: string): Promise<string | null> {
    const res = await fetch(apiBase + endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ userId: visitorId }),
    });
    if (res.status === 403) {
      // Nginx 返回 HTML 403，后端返回 JSON 403，都要兼容
      const detail = await safeJson(res);
      window.dispatchEvent(new CustomEvent("coze-auth-blocked", { detail }));
      showToast("AI 助手暂时不可用（网络限制）", "error");
      return null;
    }
    if (res.status === 503) {
      const detail = await safeJson(res);
      window.dispatchEvent(new CustomEvent("coze-quota-exhausted", { detail }));
      showToast("AI 助手额度已用尽，请联系管理员", "warning");
      return null;
    }
    if (!res.ok) return null;
    const data = await res.json().catch(() => null);
    return data?.token ?? null;
  }

  async function safeJson(res: Response): Promise<unknown> {
    try {
      return await res.json();
    } catch {
      return null;
    }
  }

  async function ensureCozeToken(): Promise<boolean> {
    if (cozeToken) return true;
    const token = await fetchToken("/token/init");
    if (token) {
      cozeToken = token;
      return true;
    }
    return false;
  }
  async function refreshCozeToken(): Promise<boolean> {
    const token = await fetchToken("/token/refresh");
    if (token) {
      cozeToken = token;
      return true;
    }
    return false;
  }

  /** 拉取 Coze bot info 开场白（onboarding_info.prologue + suggested_questions），
      空会话时渲染为首条消息。失败静默——没有开场白聊天窗也能正常用。
      ⚠️ 端点必须是 /v1/bots/{bot_id}：原 /v3/bot/info 在 Coze v3 不存在(4000)，
      会话 token(czs_) 也无法调 get_online_info(需 PAT getMetadata)。实测 SDK 壳即用
      GET /v1/bots/{id} + czs token → 200，onboarding_info 完整返回（2026-09-05 线上对照验证）。 */
  async function fetchBotInfo() {
    if (prologueFetched) return;
    if (!(await ensureCozeToken())) return;
    try {
      const res = await fetch(`${cozeApiBase}/v1/bots/${botId}`, {
        headers: { Authorization: `Bearer ${cozeToken}` },
      });
      if (!res.ok) return;
      const data = await res.json();
      const onb = data?.data?.onboarding_info;
      if (onb?.prologue) cozePrologue = onb.prologue;
      if (Array.isArray(onb?.suggested_questions)) {
        cozeSuggested = onb.suggested_questions
          .filter((s): s is string => typeof s === "string")
          .slice(0, 3);
      }
      prologueFetched = true;
    } catch {
      /* 网络失败静默，下次开面板重试 */
    }
  }

  // ==================== SSE 解析（通用） ====================
  async function readSSE(res: Response, onEvent: (event: string, data: string) => void) {
    const reader = res.body?.getReader();
    if (!reader) return;
    const decoder = new TextDecoder();
    let buffer = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      // 统一 \r\n → \n：SSE 事件块分隔符在 CRLF 下是 \r\n\r\n（不含 \n\n），
      // 不归一化会切分失效导致整条流收不到
      buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, "\n");
      let idx: number;
      while ((idx = buffer.indexOf("\n\n")) >= 0) {
        const raw = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        emitBlock(raw, onEvent);
      }
    }
    if (buffer.trim()) emitBlock(buffer, onEvent);
  }

  function emitBlock(raw: string, onEvent: (event: string, data: string) => void) {
    let event = "message";
    const datas: string[] = [];
    for (const line of raw.split("\n")) {
      const l = line.replace(/\r$/, "");
      if (l.startsWith("event:")) event = l.slice(6).trim();
      else if (l.startsWith("data:")) datas.push(l.slice(5).trimStart());
    }
    if (datas.length) onEvent(event, datas.join("\n"));
  }

  // ==================== Coze 侧（直连 v3/chat，解析 tool_response） ====================
  /** 追加/合并流式 answer：兼容「全量重发」与「增量追加」两种语义。
      修复卡会话根因：delta 已拼出全文后 conversation.message.completed 又发一遍完整 answer，
      旧逻辑因长度相等（chunk.length > prev.length 为 false）走 prev+chunk 把整段重复拼接，
      污染历史 → 下轮模型基于垃圾上下文作答。改为互为前缀取长。 */
  function mergeAnswer(prev: string, chunk: string): string {
    if (!chunk) return prev;
    if (!prev) return chunk;
    if (chunk.startsWith(prev)) return chunk; // 全量/累积重发（含长度相等）→ 整体替换
    if (prev.startsWith(chunk)) return prev; // 更短重发 / 迟到首段 → 保留已收
    return prev + chunk; // 纯增量 → 直接拼接
  }

  function updateLastAssistant(k: AgentKey, content: string) {
    const msgs = agents[k].messages;
    const last = msgs[msgs.length - 1];
    if (last && last.role === "assistant") {
      last.content = content;
    }
  }

  /** 从 JWT 中段（payload）解出过期毫秒时间戳；解不出返回 NaN */
  function jwtExpiryMs(jwt: string): number {
    try {
      const seg = jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
      const bin = atob(seg + "=".repeat((4 - (seg.length % 4)) % 4));
      const exp = (JSON.parse(bin) as { exp?: number }).exp;
      return typeof exp === "number" && Number.isFinite(exp) ? exp * 1000 : NaN;
    } catch {
      return NaN;
    }
  }

  /** 解析 tool_response 内容，命中鉴权结果则保存每日 JWT。
      历次契约（全部兼容，判定只认放行铁律）：
      - spec 版：{ success:true, token, expiresAt }（后端/指南约定字段名）
      - Coze v2 实况：{ key:<JWT>, output:"鉴权成功", ... }
      - Coze v3 实况（2026-09-05 重发后实测，须带 / 前缀才命中鉴权流）：
        { successCode:"true", hasToken:"true", key:<JWT>, output:"鉴权成功", output2, output3 }
        —— successCode/hasToken 是工作流节点输出的「字符串布尔」，仅旁证；key 仍为真 JWT。
      放行铁律 = 拿到非空、结构合法、且能解出过期时间的 JWT；
      拒绝信号 = success:false / successCode:"false" / hasToken:"false" / key 为空串
      （后端 INVALID_CODE 拒绝时 key 为空 → 永不满足放行铁律，不解锁）。 */
  function handleToolResponse(content: string) {
    try {
      const parsed = JSON.parse(content);
      const data = typeof parsed === "string" ? JSON.parse(parsed) : parsed;
      if (!data || typeof data !== "object") return;
      // 放行铁律兜底：token/key 结构非法（含拒绝时后端返回的空 key）一律不解锁
      const jwt: unknown = data.token ?? data.key;
      if (
        typeof jwt !== "string" ||
        !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(jwt)
      )
        return;
      const expiresAt =
        typeof data.expiresAt === "number"
          ? data.expiresAt
          : jwtExpiryMs(jwt);
      if (!Number.isFinite(expiresAt)) return; // 解不出过期时间 → 拒绝解锁
      const changed =
        auth.token !== jwt || auth.expiresAt !== expiresAt;
      auth.token = jwt;
      auth.expiresAt = expiresAt;
      saveAuth();
      if (changed) showToast("鉴权成功，dify 已解锁", "success");
    } catch {
      /* tool_response 非鉴权 JSON，忽略 */
    }
  }

  /** 累积 Coze follow_up 追问建议（#15 修正）：Coze v3 每条 follow_up 的
      conversation.message.completed 事件，其 content 是单句追问建议（直接
      JSON.parse 会抛错）——旧版 bot 可能给 JSON 数组字符串，统一兼容：
      数组逐条并入、单句直接并入；会话内去重并最多留 3 条（session-only，
      随 sendCoze 每轮开始清空）。 */
  function addFollowUp(content: string) {
    let parsed: unknown = null;
    try {
      parsed = JSON.parse(content);
    } catch {
      /* 单句建议 → parsed 保持 null，按单句并入 */
    }
    const items: string[] = Array.isArray(parsed)
      ? parsed.filter((s): s is string => typeof s === "string")
      : [String(content ?? "").trim()];
    const cur = agents.coze.followUps;
    const merged = [...cur];
    for (const s of items) {
      const t = s.trim();
      if (t && !merged.includes(t) && merged.length < 3) merged.push(t);
    }
    if (merged.length !== cur.length) agents.coze.followUps = merged;
  }

  /** 构建 Coze 请求历史（auto_save_history:false → 无服务端记忆，每次全量下发）：
      - 空内容过滤 + -40 条截断；追问引用注入 content 前部（引文截断 200 字防撑爆上下文）
      - 「删除单条回复」可能造成同角色相邻 → 合并保交替（Coze 要求 user/assistant 交替、末条 user） */
  function buildCozeHistory() {
    const rows: { role: "user" | "assistant"; content: string }[] = [];
    for (const m of agents.coze.messages.filter((m) => m.content).slice(-40)) {
      const content = m.quote
        ? `引用上文：「${m.quote.slice(0, 200)}」\n\n${m.content}`
        : m.content;
      const last = rows[rows.length - 1];
      if (last && last.role === m.role) last.content += `\n\n${content}`;
      else rows.push({ role: m.role, content });
    }
    return rows;
  }

  async function sendCoze(prefill?: string) {
    if (agents.coze.streaming) return;
    const text = (prefill ?? input).trim();
    if (!text) return;
    // 点建议 chip 走 prefill：不打扰输入框草稿；手动发送才清空输入框
    if (prefill === undefined) input = "";
    agents.coze.followUps = []; // 新对话轮次，清掉上一轮追问建议
    // 追问引用：输入框上方挂着引用条时，随本条用户消息携带（buildCozeHistory 注入 content）
    const quote = cozeQuote ? cozeQuote.content : undefined;
    agents.coze.messages.push({ role: "user", content: text, ts: Date.now(), quote });
    cozeQuote = null; // 引用条只服务当前这一问
    agents.coze.streaming = true;
    agents.coze.messages.push({ role: "assistant", content: "", ts: Date.now() });

    let streamOk = false; // 流是否完整读完：中断/abort → false，部分回复也整体撤掉
    let streamFailed = false; // 是否已 toast 过错误（回滚时避免重复提示）
    try {
      if (!(await ensureCozeToken())) return;

      // 携带完整历史（auto_save_history:false → 无服务端记忆，每次全量下发）
      // 上限 40 条（约 20 轮）+ 同角色合并：buildCozeHistory 统一处理
      const history = buildCozeHistory();

      const body = {
        bot_id: botId,
        user_id: visitorId,
        stream: true,
        auto_save_history: false,
        additional_messages: history,
      };

      let res = await fetch(`${cozeApiBase}/v3/chat`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${cozeToken}`,
        },
        body: JSON.stringify(body),
      });

      // token 失效 → 刷新一次重试
      if ((res.status === 401 || res.status === 403) && (await refreshCozeToken())) {
        res = await fetch(`${cozeApiBase}/v3/chat`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${cozeToken}`,
          },
          body: JSON.stringify(body),
        });
      }

      if (!res.ok) {
        const detail = await safeJson(res);
        if (res.status === 429) {
          showToast("发送太频繁，请稍后再试", "warning");
          streamFailed = true;
        } else if (res.status === 500 || res.status >= 502) {
          showToast("AI 助手暂时无法回复，请稍后重试", "error");
          console.error("[AgentChat] Coze chat 失败:", res.status, detail);
          streamFailed = true;
        }
        return;
      }

      let assistantText = "";
      await readSSE(res, (event, data) => {
        // 流式增量线名实测 = conversation.message.delta（2026-09-05 抓包确认，旧监听
        // conversation.chat.message.delta 是错的 → delta 全被丢弃、只剩整段蹦出）；
        // conversation.chat.message.delta 一并保留兜底。tool_response/最终 answer 走
        // conversation.message.completed——两类都收，mergeAnswer 兼容全量/增量两种语义
        if (
          event === "conversation.message.completed" ||
          event === "conversation.chat.message.delta" ||
          event === "conversation.message.delta"
        ) {
          try {
            const msg = JSON.parse(data);
            if (msg.type === "answer" && msg.content) {
              assistantText = mergeAnswer(assistantText, msg.content);
              updateLastAssistant("coze", assistantText);
            } else if (msg.type === "tool_response" && msg.content) {
              handleToolResponse(msg.content);
            } else if (msg.type === "follow_up" && msg.content) {
              // 回复后的追问建议：v3 每事件 content 是单句，逐条累积为可点 chips
              addFollowUp(msg.content);
            }
          } catch {
            /* 事件解析失败忽略 */
          }
        } else if (event === "conversation.chat.failed") {
          showToast("AI 助手回复失败，请稍后重试", "error");
          streamFailed = true;
        }
      });
      streamOk = true; // 流完整读完（若走 failed 事件 → assistantText 仍空，由 finally 内容检查兜底）
    } catch (err) {
      console.error("[AgentChat] Coze 流中断:", err);
      showToast("网络连接中断，请稍后重试", "error");
      streamFailed = true;
    } finally {
      agents.coze.streaming = false;
      // 未完成轮次整体撤掉：流中断（含刷新时 abort）/ 请求失败 / 回复为空 →
      // 本轮 user + 空 assistant 一并回滚，文本还给输入框（点发送即重试）。
      // 绝不把未完成轮次写进历史（否则历史尾 user → 下轮破坏交替 → 卡会话）
      const msgs = agents.coze.messages;
      const last = msgs[msgs.length - 1];
      const prev = msgs[msgs.length - 2];
      const incomplete = !streamOk || (last?.role === "assistant" && !last.content);
      if (incomplete && last?.role === "assistant" && prev?.role === "user") {
        agents.coze.messages = msgs.slice(0, -2);
        if (prefill === undefined) input = prev.content;
        // 空回复/静默失败：前面没 toast 过错误才提示，否则只回滚不打扰
        if (!streamFailed) showToast("AI 助手没有回复，请重试", "warning");
      }
      saveMessages("coze");
    }
  }

  // ==================== Dify 侧（后端代理，需每日 JWT） ====================
  async function sendDify() {
    if (agents.dify.streaming) return;
    if (!isAuthValid) {
      showToast("dify 未解锁", "warning");
      return;
    }
    const text = input.trim();
    if (!text) return;
    input = "";
    agents.dify.messages.push({ role: "user", content: text, ts: Date.now() });
    agents.dify.streaming = true;
    agents.dify.messages.push({ role: "assistant", content: "", ts: Date.now() });

    let streamOk = false; // 流是否完整读完：中断/abort → false，部分回复也整体撤掉
    let streamFailed = false; // 是否已 toast 过错误（回滚时避免重复提示）
    try {
      const res = await fetch(`${apiBase}/dify/chat`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${auth.token}`,
        },
        body: JSON.stringify({
          query: text,
          conversationId: agents.dify.conversationId,
        }),
      });

      if (res.status === 401 || res.status === 403) {
        // 每日 JWT 无效/过期 → 清空凭据，重新锁定
        auth = {};
        saveAuth();
        showToast("dify 通行证已过期", "warning");
        streamFailed = true;
        return;
      }
      if (!res.ok) {
        const detail = await safeJson(res);
        if (res.status === 429) {
          showToast("发送太频繁，请稍后再试", "warning");
          streamFailed = true;
        } else {
          showToast("dify 暂时无法回复，请稍后重试", "error");
          console.error("[AgentChat] Dify chat 失败:", res.status, detail);
          streamFailed = true;
        }
        return;
      }

      // 后端代理透传 Dify SSE：message（answer 实测为增量分片，mergeAnswer 合并）/
      // message_end / error / ping
      let assistantText = "";
      await readSSE(res, (event, data) => {
        if (event === "message" || event === "message_end") {
          try {
            const d = JSON.parse(data);
            if (typeof d.answer === "string") {
              // Dify message.answer 是增量分片（非全量累计），须逐片合并
              assistantText = mergeAnswer(assistantText, d.answer);
              updateLastAssistant("dify", assistantText);
            }
            if (d.conversation_id) {
              agents.dify.conversationId = d.conversation_id;
              saveDifyConv();
            }
          } catch {
            /* 忽略 */
          }
        } else if (event === "error") {
          try {
            const d = JSON.parse(data);
            showToast(d.message || "dify 出错了", "error");
          } catch {
            showToast("dify 出错了", "error");
          }
          streamFailed = true;
        }
      });
      streamOk = true;
    } catch (err) {
      console.error("[AgentChat] Dify 流中断:", err);
      showToast("网络连接中断，请稍后重试", "error");
      streamFailed = true;
    } finally {
      agents.dify.streaming = false;
      // 与 Coze 同：未完成轮次撤掉（刷新/流中断/失败 → user + 空 assistant 回滚），文本还给输入框
      const msgs = agents.dify.messages;
      const last = msgs[msgs.length - 1];
      const prev = msgs[msgs.length - 2];
      const incomplete = !streamOk || (last?.role === "assistant" && !last.content);
      if (incomplete && last?.role === "assistant" && prev?.role === "user") {
        agents.dify.messages = msgs.slice(0, -2);
        input = prev.content;
        // 空回复/静默失败：前面没 toast 过错误才提示
        if (!streamFailed) showToast("AI 助手没有回复，请重试", "warning");
      }
      saveMessages("dify");
    }
  }

  // ==================== 新对话（清空当前 agent 会话，只清所在 tab） ====================
  /** 点击直接初始化，无需二次确认 */
  function onNewChatClick() {
    if (agents[activeAgent].messages.length === 0) {
      return; // 已是空会话：连按静默拦截，不再弹「已经是新对话了」
    }
    clearActiveConversation();
  }
  /** 只清 activeAgent 的会话：coze tab 点「新对话」绝不触碰 dify（反之亦然） */
  function clearActiveConversation() {
    const k = activeAgent;
    agents[k].messages = [];
    agents[k].followUps = [];
    if (k === "dify") {
      agents.dify.conversationId = undefined; // Dify 会话在服务端，一并重置
      saveDifyConv();
    }
    cozeQuote = null;
    saveMessages(k);
    showToast("已开启新对话", "success");
  }

  // ==================== 单条消息操作（仅 Coze agent，hover 显示） ====================
  async function copyMessage(msg: ChatMessage) {
    try {
      await navigator.clipboard.writeText(msg.content);
      showToast("已复制", "success");
    } catch {
      showToast("复制失败，请手动选择文本", "error");
    }
  }
  /** 追问：引用该条回复 → 引用条挂输入框上方 + 聚焦输入框，等用户继续问（对齐 SDK isNeedQuote） */
  function quoteMessage(msg: ChatMessage) {
    cozeQuote = { ...msg };
    requestAnimationFrame(() => {
      textInput?.focus();
      textInput?.scrollIntoView({ block: "nearest" });
    });
  }
  function deleteMessage(msg: ChatMessage) {
    agents.coze.messages = agents.coze.messages.filter((m) => m !== msg);
    if (cozeQuote?.ts === msg.ts) cozeQuote = null; // 删的是正引用的那条 → 引用条一并撤下
    saveMessages("coze");
    showToast("已删除该条回复", "success");
  }

  // ==================== 发送入口 ====================
  function send() {
    if (activeAgent === "coze") void sendCoze();
    else void sendDify();
    // 发送后复位输入框高度（bind:value 清空文本但不会重置行高）
    if (textInput) textInput.style.height = "auto";
  }

  function onInputKeydown(e: KeyboardEvent) {
    // 中文输入法组合期间不触发送；Shift+Enter 换行
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send();
    }
  }

  function autoResize(e: Event) {
    const ta = e.currentTarget as HTMLTextAreaElement;
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 120)}px`;
  }

  // ==================== 挂载 ====================
  onMount(() => {
    // 访客 ID（与旧版一致，跨会话关联）
    visitorId = getLS("coze_visitor_id") || "";
    if (!visitorId) {
      visitorId = `v_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      setLS("coze_visitor_id", visitorId);
    }

    clearLegacyCozeCache();
    loadPersisted();
    bindBall();
    maybeShowGreeting();
    void fetchBotInfo(); // 预取开场白（空会话首条消息）

    // Swup 切页后强制收起聊天窗（浮窗跨页存活，coze-chat-open 会残留）
    const handleNavigate = () => closePanel();
    if (window.swup?.hooks) {
      window.swup.hooks.on("content:replace", handleNavigate);
      swupBound = true;
    } else {
      document.addEventListener("swup:enable", () => {
        if (!swupBound && window.swup?.hooks) {
          window.swup.hooks.on("content:replace", handleNavigate);
          swupBound = true;
        }
      });
    }

    // 时钟节拍：驱动每日 JWT 过期的 UI 翻转（仅页面存活期间，30s 一次，开销可忽略）
    const nowTick = setInterval(() => {
      now = Date.now();
    }, 30_000);

    return () => {
      clearTimeout(toastTimer);
      clearInterval(nowTick);
    };
  });

  // 消息更新 / 切换 agent 时自动滚到底部
  $effect(() => {
    if (!panelOpen) return;
    const msgs = agents[activeAgent].messages;
    const last = msgs[msgs.length - 1];
    void last?.content; // 订阅流式内容
    void agents.coze.followUps; // 追问建议 chips 出现时也滚到底
    requestAnimationFrame(() => {
      if (msgBox) msgBox.scrollTop = msgBox.scrollHeight;
    });
  });

  // ==================== 移动端键盘抬升 + 背景滚动锁定（#10/#13/#14） ====================
  // #10/#13 软键盘：移动端软键盘不压缩布局视口，固定 bottom 面板的输入区会被盖住。
  // 用 visualViewport 量出「可视区底到布局底的空隙 gap」（= 键盘遮挡像素）写进根级
  // CSS 变量 --agent-kb，CSS 据此把面板底部抬到键盘上方（见 @media .kb-lift）。
  // #13 真机「键盘仍挡输入框」补强：键盘只在输入框聚焦时弹起 → 抬升判据收窄为
  // 「面板开 + 窄屏 + 输入框聚焦 + gap>120」；聚焦后 700ms 内持续补测（真机 focusin
  // 常先于 visualViewport 收缩触发、vv resize 偶发漏发，迟到的收缩靠补测捞回），
  // 并补挂 window resize（部分 Android 只发 window resize、不发 vv resize）。
  let kbRetry: ReturnType<typeof setInterval> | undefined;

  function isTextFocused() {
    const el = document.activeElement;
    return !!el && el.tagName === "TEXTAREA";
  }

  function updateKbLift() {
    const narrow = window.innerWidth <= 768;
    const vv = window.visualViewport ?? null;
    let gap = 0;
    if (vv) gap = Math.max(0, window.innerHeight - (vv.offsetTop + vv.height));
    const up = panelOpen && narrow && isTextFocused() && gap > 120;
    if (up === kbUp) return;
    kbUp = up;
    if (up) document.documentElement.style.setProperty("--agent-kb", `${gap}px`);
    else document.documentElement.style.removeProperty("--agent-kb");
  }

  function startKbRetry() {
    if (kbRetry) return;
    kbRetry = setInterval(updateKbLift, 200);
    setTimeout(() => stopKbRetry(), 700);
  }
  function stopKbRetry() {
    if (kbRetry) {
      clearInterval(kbRetry);
      kbRetry = undefined;
    }
  }

  // #14 背景滚动锁定：面板开启 + 窄屏 → 给 <html> 挂 agent-chat-open（CSS 置
  // overflow:hidden），禁用下方文章页的上下滑；配合 .agent-messages 的
  // overscroll-behavior: contain 阻断滚动手势在到达消息区顶/底后串到背景页。
  function updateScrollLock() {
    const on = panelOpen && window.innerWidth <= 768;
    document.documentElement.classList.toggle("agent-chat-open", on);
  }

  const onFocusIn = () => {
    startKbRetry();
    updateKbLift();
  };
  const onFocusOut = () => {
    stopKbRetry();
    updateKbLift();
  };
  const onViewport = () => {
    updateScrollLock();
    updateKbLift();
  };

  // 面板开合后各重算一次（开合 → 滚动锁 + 抬升状态复位）
  $effect(() => {
    void panelOpen;
    const raf = requestAnimationFrame(onViewport);
    return () => cancelAnimationFrame(raf);
  });

  // 视口/方向/focus 变化都重算（监听一次即够；visualViewport.resize 覆盖键盘弹收动画）
  $effect(() => {
    const evt: EventTarget = window.visualViewport ?? window;
    evt.addEventListener("resize", onViewport);
    if (window.visualViewport) evt.addEventListener("scroll", onViewport); // iOS 聚焦自动滚动会平移视口
    window.addEventListener("resize", onViewport); // 窄/宽屏切换、无 vv 的浏览器兜底
    window.addEventListener("orientationchange", onViewport);
    window.addEventListener("focusin", onFocusIn);
    window.addEventListener("focusout", onFocusOut);
    return () => {
      evt.removeEventListener("resize", onViewport);
      if (window.visualViewport) evt.removeEventListener("scroll", onViewport);
      window.removeEventListener("resize", onViewport);
      window.removeEventListener("orientationchange", onViewport);
      window.removeEventListener("focusin", onFocusIn);
      window.removeEventListener("focusout", onFocusOut);
    };
  });
</script>

<!-- ===== 聊天窗面板 ===== -->
<div
  class="agent-panel"
  class:open={panelOpen}
  class:kb-lift={kbUp}
  role="dialog"
  aria-hidden={!panelOpen}
  aria-label="博客 AI 助手"
>
  <!-- 头部：双 agent 切换 + 关闭 -->
  <div class="agent-header">
    <div class="agent-tabs" role="tablist">
      <button
        type="button"
        class="agent-tab"
        class:active={activeAgent === "coze"}
        role="tab"
        aria-selected={activeAgent === "coze"}
        onclick={() => switchAgent("coze")}
      >
        <span class="tab-dot coze"></span>博客助手
      </button>
      <button
        type="button"
        class="agent-tab"
        class:active={activeAgent === "dify"}
        class:locked={!isAuthValid}
        role="tab"
        aria-selected={activeAgent === "dify"}
        onclick={() => switchAgent("dify")}
      >
        <span class="tab-dot dify"></span>dify
        {#if !isAuthValid}
          <span class="tab-lock" title="未解锁">🔒</span>
        {:else}
          <span class="tab-unlock" title="已解锁">✓</span>
        {/if}
      </button>
    </div>
    <button
      type="button"
      class="agent-newchat"
      data-tip="新对话"
      aria-label="新对话"
      disabled={agents[activeAgent].streaming}
      onclick={onNewChatClick}
    >
      <Icon icon="material-symbols:add-rounded" size="md" />
    </button>
    <button
      type="button"
      class="agent-close"
      data-tip="关闭"
      aria-label="关闭 AI 助手"
      onclick={closePanel}
    >
      ×
    </button>
  </div>

  <!-- 主体 -->
  <div class="agent-body">
    {#if activeAgent === "dify" && !isAuthValid}
      <!-- 大闸门锁屏 -->
      <div class="dify-lock">
        <div class="lock-icon">🔒</div>
        <p class="lock-title">dify 已锁定</p>
        <button type="button" class="lock-btn" onclick={() => switchAgent("coze")}>
          返回博客助手
        </button>
      </div>
    {:else}
      <div class="agent-messages" bind:this={msgBox}>
        {#if activeAgent === "coze" && agents.coze.messages.length === 0 && cozePrologue}
          <!-- 空会话开场白：渲染为首条 assistant 消息（不进 messages 数组，不参与历史） -->
          <div class="msg assistant">
            <div class="bubble">{cozePrologue}</div>
          </div>
          {#if cozeSuggested.length}
            <div class="suggestions">
              {#each cozeSuggested as q, i (q + i)}
                <button
                  type="button"
                  class="suggest-chip"
                  disabled={agents.coze.streaming}
                  onclick={() => void sendCoze(q)}
                >
                  {q}
                </button>
              {/each}
            </div>
          {/if}
        {/if}
        {#each agents[activeAgent].messages as msg, i (msg.ts + "-" + i)}
          <div class="msg {msg.role}">
            {#if msg.content}
              <div class="bubble">
                {#if msg.quote}
                  <!-- 追问消息的引用块：引用的是哪条回复 -->
                  <div class="bubble-quote">引用：「{msg.quote}」</div>
                {/if}
                {msg.content}
              </div>
            {:else if agents[activeAgent].streaming}
              <div class="bubble typing"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
            {/if}
            {#if msg.role === "assistant" && msg.content}
              <!-- 单条操作（hover 显示）：复制=双 agent 对等；追问/删除=仅 Coze
                   （8-25 裁决：dify 会话在服务端，本地删/追问不同步上下文，不提供） -->
              <div class="msg-actions">
                <button
                  type="button"
                  class="msg-act"
                  data-tip="复制"
                  aria-label="复制"
                  onclick={() => void copyMessage(msg)}
                >
                  <Icon icon="material-symbols:content-copy" size="sm" />
                </button>
                {#if activeAgent === "coze"}
                  <button
                    type="button"
                    class="msg-act"
                    data-tip="追问"
                    aria-label="追问"
                    onclick={() => quoteMessage(msg)}
                  >
                    <Icon icon="material-symbols:reply-rounded" size="sm" />
                  </button>
                  <button
                    type="button"
                    class="msg-act danger"
                    data-tip="删除"
                    aria-label="删除"
                    onclick={() => deleteMessage(msg)}
                  >
                    <Icon icon="material-symbols:delete-rounded" size="sm" />
                  </button>
                {/if}
              </div>
            {/if}
          </div>
        {/each}
        {#if activeAgent === "coze" && agents.coze.followUps.length}
          <!-- 回复后的追问建议（follow_up 事件）：渲染为可点 chips -->
          <div class="suggestions">
            {#each agents.coze.followUps as q, i (q + i)}
              <button
                type="button"
                class="suggest-chip"
                disabled={agents.coze.streaming}
                onclick={() => void sendCoze(q)}
              >
                {q}
              </button>
            {/each}
          </div>
        {/if}
      </div>
    {/if}
  </div>

  <!-- 输入区 -->
  {#if !(activeAgent === "dify" && !isAuthValid)}
    {#if activeAgent === "coze" && cozeQuote}
      <!-- 追问引用条：对齐 SDK isNeedQuote，发送时随消息携带 -->
      <div class="quote-bar">
        <span class="quote-label">追问</span>
        <span class="quote-text">{cozeQuote.content}</span>
        <button
          type="button"
          class="quote-clear"
          data-tip="取消引用"
          aria-label="取消引用"
          onclick={() => (cozeQuote = null)}
        >
          ×
        </button>
      </div>
    {/if}
    <div class="agent-footer">
      <textarea
        bind:this={textInput}
        bind:value={input}
        rows="1"
        maxlength="2000"
        placeholder="输入消息…"
        aria-label="消息输入框"
        oninput={autoResize}
        onkeydown={onInputKeydown}
      ></textarea>
      <button
        type="button"
        class="send-btn"
        data-tip="发送"
        aria-label="发送"
        disabled={!input.trim() || agents[activeAgent].streaming}
        onclick={send}
      >
        {#if agents[activeAgent].streaming}
          <Icon icon="svg-spinners:3-dots-bounce" size="md" />
        {:else}
          <Icon icon="material-symbols:send-rounded" size="md" />
        {/if}
      </button>
    </div>
  {/if}
</div>

<!-- ===== Toast（全局浮层，与旧版位置一致） ===== -->
{#if toast}
  <div class="agent-toast {toast.type}" role="status" onclick={() => (toast = null)}>
    <span class="toast-icon">{toast.type === "error" ? "✕" : toast.type === "success" ? "✓" : "⚠"}</span>
    <span>{toast.text}</span>
  </div>
{/if}

<style>
  /* ===== 聊天窗面板（主题变量来自 src/styles/variables.styl） ===== */
  .agent-panel {
    position: fixed;
    right: 1rem;
    bottom: 1rem;
    z-index: 1020; /* 高于 FloatingControls(1000)/FloatingTOC(1001)，低于 Toast(9999) */
    width: 380px;
    max-width: calc(100vw - 2rem);
    height: min(560px, calc(100vh - 2rem));
    max-height: calc(100vh - 2rem);
    height: min(560px, calc(100dvh - 2rem)); /* 支持 dvh 的浏览器优先（移动端动态视口） */
    max-height: calc(100dvh - 2rem);
    display: flex;
    flex-direction: column;
    background: var(--card-bg);
    border: 1px solid var(--line-divider);
    border-radius: var(--radius-2xl);
    box-shadow: var(--shadow-xl);
    /* 注意：不开 overflow:hidden，否则头部按钮的 tooltip 向上溢出面板顶会被裁掉。
       消息滚动的圆角裁剪已由 .agent-body 的 overflow:hidden 承担。 */
    opacity: 0;
    visibility: hidden;
    transform: translateY(16px) scale(0.98);
    transform-origin: bottom right;
    transition:
      opacity var(--duration-medium) var(--ease-standard),
      transform var(--duration-medium) var(--ease-decelerate),
      visibility var(--duration-medium);
  }
  .agent-panel.open {
    opacity: 1;
    visibility: visible;
    transform: translateY(0) scale(1);
  }

  /* --- 头部 --- */
  .agent-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    padding: 0.6rem 0.75rem;
    border-bottom: 1px solid var(--line-divider);
    flex-shrink: 0;
  }
  .agent-tabs {
    display: flex;
    gap: 0.25rem;
    flex: 1;
  }
  .agent-tab {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.4rem 0.7rem;
    border: none;
    border-radius: var(--radius-lg);
    background: none;
    color: var(--content-meta);
    font-size: 13px;
    line-height: 1;
    cursor: pointer;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .agent-tab:hover {
    background: var(--btn-regular-bg);
    color: var(--deep-text);
  }
  .agent-tab.active {
    background: color-mix(in oklab, var(--primary) 14%, transparent);
    color: var(--title-active);
    font-weight: 600;
  }
  .tab-dot {
    width: 8px;
    height: 8px;
    border-radius: var(--radius-full);
    flex-shrink: 0;
  }
  .tab-dot.coze {
    background: color-mix(in oklab, var(--primary) 70%, transparent);
  }
  .tab-dot.dify {
    background: oklch(0.65 0.16 255);
  }
  .tab-lock {
    font-size: 11px;
    opacity: 0.85;
  }
  .tab-unlock {
    font-size: 11px;
    color: #2e9e5b;
    font-weight: 700;
  }
  .agent-tab.locked {
    opacity: 0.72;
  }
  .agent-close {
    flex-shrink: 0;
    width: 28px;
    height: 28px;
    border: none;
    border-radius: var(--radius-full);
    background: none;
    color: var(--content-meta);
    font-size: 18px;
    line-height: 1;
    cursor: pointer;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .agent-close:hover {
    background: var(--btn-regular-bg);
    color: var(--deep-text);
  }
  /* 新对话：图标按钮，与关闭同尺寸、同风格（方形圆角，hover 主题色） */
  .agent-newchat {
    flex-shrink: 0;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 1px solid var(--line-divider);
    border-radius: var(--radius-full);
    background: none;
    color: var(--content-meta);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .agent-newchat:hover:not(:disabled) {
    background: var(--btn-regular-bg);
    color: var(--primary);
  }
  .agent-newchat:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* --- 主体 --- */
  .agent-body {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .agent-messages {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    overscroll-behavior: contain; /* 顶/底到头不再把滚动串到背景文章页（#14） */
    padding: 0.75rem;
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .msg {
    display: flex;
    max-width: 88%;
    position: relative; /* 单条操作按钮的定位锚点 */
  }
  .msg.user {
    align-self: flex-end;
    justify-content: flex-end;
  }
  .msg.assistant {
    align-self: flex-start;
  }
  .bubble {
    padding: 0.55rem 0.8rem;
    border-radius: var(--radius-xl);
    font-size: 14px;
    line-height: 1.55;
    word-break: break-word;
    white-space: pre-wrap;
    color: var(--deep-text);
  }
  .msg.user .bubble {
    background: var(--primary);
    color: oklch(1 0 0);
    border-bottom-right-radius: var(--radius-sm);
  }
  .msg.assistant .bubble {
    background: var(--btn-regular-bg);
    border: 1px solid var(--line-divider);
    border-bottom-left-radius: var(--radius-sm);
  }
  /* 气泡内引用块（追问消息） */
  .bubble-quote {
    margin-bottom: 0.4rem;
    padding: 0.3rem 0.5rem;
    border-left: 3px solid color-mix(in oklab, var(--primary) 50%, transparent);
    border-radius: var(--radius-sm);
    background: color-mix(in oklab, var(--primary) 7%, transparent);
    font-size: 12px;
    line-height: 1.4;
    color: var(--content-meta);
    max-height: 3.6em;
    overflow: hidden;
  }
  /* 单条消息操作（仅 Coze assistant，hover 出现） */
  .msg-actions {
    position: absolute;
    top: -0.5rem;
    right: 0;
    display: flex;
    gap: 2px;
    padding: 2px;
    border: 1px solid var(--line-divider);
    border-radius: var(--radius-lg);
    background: var(--card-bg);
    box-shadow: var(--shadow-button);
    opacity: 0;
    visibility: hidden;
    z-index: 2;
    transition: opacity var(--duration-fast) var(--ease-standard);
  }
  .msg:hover .msg-actions {
    opacity: 1;
    visibility: visible;
  }
  .msg-act {
    border: none;
    background: none;
    width: 26px;
    height: 26px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    color: var(--content-meta);
    cursor: pointer;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .msg-act:hover {
    background: var(--btn-regular-bg);
    color: var(--primary);
  }
  .msg-act.danger:hover {
    color: #c00;
  }
  /* 流式打字动画 */
  .bubble.typing {
    display: flex;
    gap: 4px;
    align-items: center;
    padding: 0.7rem 0.85rem;
  }
  .dot {
    width: 6px;
    height: 6px;
    border-radius: var(--radius-full);
    background: var(--content-meta);
    animation: agentBlink 1.2s infinite ease-in-out;
  }
  .dot:nth-child(2) {
    animation-delay: 0.2s;
  }
  .dot:nth-child(3) {
    animation-delay: 0.4s;
  }
  @keyframes agentBlink {
    0%, 80%, 100% {
      opacity: 0.25;
      transform: translateY(0);
    }
    40% {
      opacity: 1;
      transform: translateY(-2px);
    }
  }

  /* --- 追问建议 chips（开场白预置问题 / 回复后 follow_up） --- */
  .suggestions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    padding: 0 0.25rem;
    max-width: 88%;
    align-self: flex-start;
  }
  .suggest-chip {
    padding: 0.4rem 0.75rem;
    border: 1px solid color-mix(in oklab, var(--primary) 28%, var(--line-divider));
    border-radius: var(--radius-full);
    /* 快捷指令胶囊：主题色淡染 + 稍高亮度的表面，与面板/气泡背景拉开区分度 */
    background: color-mix(in oklab, var(--primary) 13%, var(--btn-regular-bg));
    color: var(--deep-text);
    font-size: 12.5px;
    line-height: 1.45;
    text-align: left;
    cursor: pointer;
    transition:
      border-color var(--duration-fast) var(--ease-standard),
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .suggest-chip:hover:not(:disabled) {
    border-color: color-mix(in oklab, var(--primary) 70%, transparent);
    color: var(--primary);
    background: color-mix(in oklab, var(--primary) 22%, var(--btn-regular-bg));
  }
  .suggest-chip:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* --- 大闸门锁屏 --- */
  .dify-lock {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.6rem;
    padding: 1rem;
    text-align: center;
  }
  .lock-icon {
    font-size: 40px;
    opacity: 0.9;
  }
  .lock-title {
    margin: 0;
    font-size: 15px;
    font-weight: 600;
    color: var(--deep-text);
  }
  .lock-btn {
    margin-top: 0.4rem;
    padding: 0.5rem 1.1rem;
    border: none;
    border-radius: var(--radius-full);
    background: var(--primary);
    color: oklch(1 0 0);
    font-size: 14px;
    cursor: pointer;
    transition:
      transform var(--duration-fast) var(--ease-standard),
      opacity var(--duration-fast) var(--ease-standard);
  }
  .lock-btn:hover {
    transform: translateY(-1px);
    opacity: 0.92;
  }

  /* --- 输入区 --- */
  .agent-footer {
    display: flex;
    align-items: flex-end;
    gap: 0.5rem;
    padding: 0.65rem 0.75rem;
    border-top: 1px solid var(--line-divider);
    flex-shrink: 0;
  }
  .agent-footer textarea {
    flex: 1;
    resize: none;
    min-height: 36px;
    max-height: 120px;
    padding: 0.5rem 0.7rem;
    border: 1px solid var(--line-divider);
    border-radius: var(--radius-lg);
    background: var(--btn-regular-bg);
    color: var(--deep-text);
    font-size: 14px;
    line-height: 1.5;
    font-family: inherit;
    outline: none;
    transition: border-color var(--duration-fast) var(--ease-standard);
  }
  .agent-footer textarea:focus {
    border-color: color-mix(in oklab, var(--primary) 55%, transparent);
  }
  /* 占位符显式配色：亮色=中灰提示；暗色覆盖见 html.dark（近白） */
  .agent-footer textarea::placeholder {
    color: color-mix(in oklab, var(--deep-text) 46%, transparent);
  }
  .send-btn {
    flex-shrink: 0;
    width: 36px;
    height: 36px;
    padding: 0;
    border: none;
    border-radius: var(--radius-full);
    background: var(--primary);
    color: oklch(1 0 0);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition:
      opacity var(--duration-fast) var(--ease-standard),
      transform var(--duration-fast) var(--ease-standard);
  }
  .send-btn:hover:not(:disabled) {
    opacity: 0.92;
    transform: translateY(-1px);
  }
  .send-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* --- 追问引用条（输入框上方） --- */
  .quote-bar {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.4rem 0.75rem;
    border-top: 1px solid var(--line-divider);
    background: color-mix(in oklab, var(--primary) 6%, var(--card-bg));
    flex-shrink: 0;
  }
  .quote-label {
    flex-shrink: 0;
    font-size: 12px;
    font-weight: 600;
    color: var(--primary);
  }
  .quote-text {
    flex: 1;
    min-width: 0;
    font-size: 12.5px;
    line-height: 1.4;
    color: var(--content-meta);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .quote-clear {
    flex-shrink: 0;
    width: 22px;
    height: 22px;
    border: none;
    border-radius: var(--radius-full);
    background: none;
    color: var(--content-meta);
    font-size: 15px;
    line-height: 1;
    cursor: pointer;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .quote-clear:hover {
    background: var(--btn-regular-bg);
    color: var(--deep-text);
  }

  /* ===== 图标按钮 tooltip（data-tip）=====
     特例：.suggest-chip / .agent-tab 是想展示内容的按键，不是"具名按钮"，
     不挂 data-tip。凡挂了 data-tip 的按钮，hover/focus-visible 时在正上方
     弹出提示文本 + 小箭头（按钮名字）。深底浅字，亮暗主题通用（--hue 跟随站点色相）。 */
  [data-tip] {
    position: relative;
  }
  [data-tip]::before,
  [data-tip]::after {
    pointer-events: none;
    opacity: 0;
    visibility: hidden;
    transition:
      opacity var(--duration-fast) var(--ease-standard),
      visibility var(--duration-fast);
  }
  [data-tip]::after {
    content: attr(data-tip);
    position: absolute;
    bottom: calc(100% + 9px);
    left: 50%;
    transform: translateX(-50%) translateY(4px);
    padding: 5px 9px;
    border-radius: var(--radius-md);
    background: oklch(0.22 0.012 var(--hue));
    color: oklch(0.97 0.005 var(--hue));
    font-size: 12px;
    line-height: 1.4;
    white-space: nowrap;
    z-index: 60;
  }
  [data-tip]::before {
    content: "";
    position: absolute;
    bottom: calc(100% + 4px);
    left: 50%;
    transform: translateX(-50%) translateY(4px) rotate(45deg);
    width: 8px;
    height: 8px;
    background: oklch(0.22 0.012 var(--hue));
    z-index: 60;
  }
  [data-tip]:hover::after,
  [data-tip]:focus-visible::after {
    opacity: 1;
    visibility: visible;
    transform: translateX(-50%) translateY(0);
  }
  [data-tip]:hover::before,
  [data-tip]:focus-visible::before {
    opacity: 1;
    visibility: visible;
    transform: translateX(-50%) translateY(0) rotate(45deg);
  }

  /* --- Toast --- */
  .agent-toast {
    position: fixed;
    right: 1.25rem;
    bottom: 5.5rem;
    z-index: 9999;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    max-width: 300px;
    padding: 0.6rem 0.9rem;
    border-radius: var(--radius-lg);
    font-size: 13px;
    line-height: 1.5;
    box-shadow: var(--shadow-button);
    animation: agentToastIn 0.25s var(--ease-standard);
    cursor: pointer;
  }
  .agent-toast.error {
    background: #fff0f0;
    color: #c00;
    border: 1px solid #ffc0c0;
  }
  .agent-toast.warning {
    background: #fffbe6;
    color: #b8860b;
    border: 1px solid #ffe58f;
  }
  .agent-toast.success {
    background: #f0fff4;
    color: #1a7f3b;
    border: 1px solid #bfe9c9;
  }
  :global(html.dark) .agent-toast.error {
    background: oklch(0.3 0.08 20);
    color: oklch(0.85 0.12 20);
    border-color: oklch(0.45 0.1 20);
  }
  :global(html.dark) .agent-toast.warning {
    background: oklch(0.32 0.08 70);
    color: oklch(0.88 0.1 70);
    border-color: oklch(0.45 0.1 70);
  }
  :global(html.dark) .agent-toast.success {
    background: oklch(0.32 0.08 150);
    color: oklch(0.88 0.1 150);
    border-color: oklch(0.45 0.1 150);
  }

  /* --- 暗色主题文字可读性 ---
     --deep-text 无暗色重定义（暗色下仍是近黑 oklch(0.25…)），
     消息气泡 / 输入框 / 锁屏标题直接拿它当文字色 → 黑底黑字看不清。
     统一换成 --btn-content（暗色下为浅色调文字）。 */
  /* AI 内容正文 + 输入实文：暗色下用近白正文色（--btn-content L≈0.75 仍偏灰、辨识度不足） */
  :global(html.dark) .msg.assistant .bubble,
  :global(html.dark) .agent-footer textarea {
    color: oklch(0.92 0.015 var(--hue));
  }
  :global(html.dark) .dify-lock .lock-title,
  :global(html.dark) .agent-tab:hover,
  :global(html.dark) .agent-close:hover,
  :global(html.dark) .suggest-chip,
  :global(html.dark) .msg-actions .msg-act,
  :global(html.dark) .quote-text,
  :global(html.dark) .quote-clear,
  :global(html.dark) .bubble-quote,
  :global(html.dark) .agent-newchat {
    color: var(--btn-content);
  }
  :global(html.dark) .msg-act.danger:hover {
    color: oklch(0.7 0.18 20);
  }
  :global(html.dark) .agent-footer textarea::placeholder {
    color: rgba(255, 255, 255, 0.6);
  }
  @keyframes agentToastIn {
    from {
      opacity: 0;
      transform: translateY(10px);
    }
    to {
      opacity: 1;
      transform: translateY(0);
    }
  }

  /* --- 移动端 --- */
  @media (max-width: 768px) {
    /* 面板开启 + 窄屏：锁死背景页面滚动（#14）。class 由 JS updateScrollLock 挂 <html> */
    :global(html.agent-chat-open),
    :global(html.agent-chat-open body) {
      overflow: hidden;
    }
    .agent-panel {
      right: 1rem;
      left: 1rem;
      width: auto;
      height: min(560px, calc(100vh - 2rem));
      height: min(560px, calc(100dvh - 2rem));
    }
    /* 软键盘弹起（#10）：updateKbLift() 把键盘遮挡像素写进根级 --agent-kb。
       顶/底同时钉住 → 面板撑满键盘以上的可视区、输入区始终可见；无键盘时永不挂此类。 */
    .agent-panel.kb-lift {
      top: 0.5rem;
      bottom: calc(var(--agent-kb, 0px) + 0.5rem);
      height: auto;
      max-height: none;
    }
    .agent-toast {
      right: 1rem;
      bottom: 5rem;
      left: 1rem;
      max-width: none;
    }
  }
</style>
