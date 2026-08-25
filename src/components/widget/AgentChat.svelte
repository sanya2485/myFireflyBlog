<script lang="ts">
  import { onMount } from "svelte";

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
  }
  interface AgentState {
    messages: ChatMessage[];
    conversationId?: string; // Dify 侧会话 id
    streaming: boolean;
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
    coze: { messages: [], streaming: false },
    dify: { messages: [], streaming: false },
  });
  let auth = $state<AuthState>({});
  let input = $state("");
  let cozeToken = $state<string | null>(null);
  let toast = $state<{ text: string; type: ToastType } | null>(null);
  let msgBox = $state<HTMLElement | null>(null);
  let textInput = $state<HTMLTextAreaElement | null>(null);

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

  function loadPersisted() {
    try {
      const a = getLS(LS_AUTH);
      if (a) auth = { ...auth, ...JSON.parse(a) };
      const cm = getLS(lsMsg("coze"));
      if (cm) agents.coze.messages = JSON.parse(cm);
      const dm = getLS(lsMsg("dify"));
      if (dm) agents.dify.messages = JSON.parse(dm);
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
    // 聚焦输入框（等待面板渲染完成）
    requestAnimationFrame(() => textInput?.focus());
  }
  function closePanel() {
    panelOpen = false;
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
    if (k === "dify" && !isAuthValid) {
      // 锁定态切过来：停留展示锁屏，引导去对暗号
      showToast("请先对暗号解锁 Dify 智库", "warning");
    }
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
  /** 追加/合并流式 answer：兼容「全量重发」与「增量追加」两种语义 */
  function mergeAnswer(prev: string, chunk: string): string {
    if (!chunk) return prev;
    if (!prev) return chunk;
    // 全量模式：新 chunk 是已收文本的超集且以旧文本开头 → 整体替换
    if (chunk.length > prev.length && chunk.startsWith(prev)) return chunk;
    return prev + chunk; // 增量模式：直接拼接
  }

  function updateLastAssistant(k: AgentKey, content: string) {
    const msgs = agents[k].messages;
    const last = msgs[msgs.length - 1];
    if (last && last.role === "assistant") {
      last.content = content;
    }
  }

  /** 解析 tool_response 内容，命中鉴权结果则保存每日 JWT */
  function handleToolResponse(content: string) {
    try {
      const parsed = JSON.parse(content);
      const data = typeof parsed === "string" ? JSON.parse(parsed) : parsed;
      if (data && data.success === true && data.token) {
        const changed =
          auth.token !== data.token || auth.expiresAt !== data.expiresAt;
        auth.token = data.token;
        auth.expiresAt = data.expiresAt;
        saveAuth();
        if (changed) showToast("鉴权成功，Dify 智库已解锁", "success");
      }
    } catch {
      /* tool_response 非鉴权 JSON，忽略 */
    }
  }

  async function sendCoze() {
    if (agents.coze.streaming) return;
    const text = input.trim();
    if (!text) return;
    input = "";
    agents.coze.messages.push({ role: "user", content: text, ts: Date.now() });
    agents.coze.streaming = true;
    agents.coze.messages.push({ role: "assistant", content: "", ts: Date.now() });

    try {
      if (!(await ensureCozeToken())) return;

      // 携带完整历史（auto_save_history:false → 无服务端记忆，每次全量下发）
      // 上限 40 条（约 20 轮）：避免无界增长撑爆模型上下文
      const history = agents.coze.messages
        .filter((m) => m.content)
        .slice(-40)
        .map((m) => ({ role: m.role, content: m.content }));

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
        if (res.status === 429) showToast("发送太频繁，请稍后再试", "warning");
        else if (res.status === 500 || res.status >= 502) {
          showToast("AI 助手暂时无法回复，请稍后重试", "error");
          console.error("[AgentChat] Coze chat 失败:", res.status, detail);
        }
        return;
      }

      let assistantText = "";
      await readSSE(res, (event, data) => {
        // 流式增量可能走 conversation.chat.message.delta；tool_response/最终 answer 走
        // conversation.message.completed——两者都收，mergeAnswer 兼容全量/增量两种语义
        if (
          event === "conversation.message.completed" ||
          event === "conversation.chat.message.delta"
        ) {
          try {
            const msg = JSON.parse(data);
            if (msg.type === "answer" && msg.content) {
              assistantText = mergeAnswer(assistantText, msg.content);
              updateLastAssistant("coze", assistantText);
            } else if (msg.type === "tool_response" && msg.content) {
              handleToolResponse(msg.content);
            }
          } catch {
            /* 事件解析失败忽略 */
          }
        } else if (event === "conversation.chat.failed") {
          showToast("AI 助手回复失败，请稍后重试", "error");
        }
      });
    } catch (err) {
      console.error("[AgentChat] Coze 流中断:", err);
      showToast("网络连接中断，请稍后重试", "error");
    } finally {
      agents.coze.streaming = false;
      saveMessages("coze");
    }
  }

  // ==================== Dify 侧（后端代理，需每日 JWT） ====================
  async function sendDify() {
    if (agents.dify.streaming) return;
    if (!isAuthValid) {
      showToast("请先对暗号解锁 Dify 智库", "warning");
      return;
    }
    const text = input.trim();
    if (!text) return;
    input = "";
    agents.dify.messages.push({ role: "user", content: text, ts: Date.now() });
    agents.dify.streaming = true;
    agents.dify.messages.push({ role: "assistant", content: "", ts: Date.now() });

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
        showToast("每日通行证已过期，请重新对暗号", "warning");
        return;
      }
      if (!res.ok) {
        const detail = await safeJson(res);
        if (res.status === 429) showToast("发送太频繁，请稍后再试", "warning");
        else {
          showToast("Dify 智库暂时无法回复，请稍后重试", "error");
          console.error("[AgentChat] Dify chat 失败:", res.status, detail);
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
            showToast(d.message || "Dify 智库出错了", "error");
          } catch {
            showToast("Dify 智库出错了", "error");
          }
        }
      });
    } catch (err) {
      console.error("[AgentChat] Dify 流中断:", err);
      showToast("网络连接中断，请稍后重试", "error");
    } finally {
      agents.dify.streaming = false;
      saveMessages("dify");
    }
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
    requestAnimationFrame(() => {
      if (msgBox) msgBox.scrollTop = msgBox.scrollHeight;
    });
  });
</script>

<!-- ===== 聊天窗面板 ===== -->
<div
  class="agent-panel"
  class:open={panelOpen}
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
        <span class="tab-dot dify"></span>Dify 智库
        {#if !isAuthValid}
          <span class="tab-lock" title="需先对暗号解锁">🔒</span>
        {:else}
          <span class="tab-unlock" title="已解锁">✓</span>
        {/if}
      </button>
    </div>
    <button
      type="button"
      class="agent-close"
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
        <p class="lock-title">Dify 智库已锁定</p>
        <p class="lock-hint">在「博客助手」里输入 <code>/对暗号 xxxx</code> 换取每日通行证</p>
        <button type="button" class="lock-btn" onclick={() => switchAgent("coze")}>
          去对暗号 →
        </button>
      </div>
    {:else}
      <div class="agent-messages" bind:this={msgBox}>
        {#each agents[activeAgent].messages as msg, i (msg.ts + "-" + i)}
          <div class="msg {msg.role}">
            {#if msg.content}
              <div class="bubble">{msg.content}</div>
            {:else if agents[activeAgent].streaming}
              <div class="bubble typing"><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- 输入区 -->
  {#if !(activeAgent === "dify" && !isAuthValid)}
    <div class="agent-footer">
      <textarea
        bind:this={textInput}
        bind:value={input}
        rows="1"
        maxlength="2000"
        placeholder={activeAgent === "coze" ? "输入消息，/对暗号 xxx 解锁 Dify…" : "输入消息…"}
        aria-label="消息输入框"
        oninput={autoResize}
        onkeydown={onInputKeydown}
      ></textarea>
      <button
        type="button"
        class="send-btn"
        disabled={!input.trim() || agents[activeAgent].streaming}
        onclick={send}
      >
        {agents[activeAgent].streaming ? "…" : "发送"}
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
    display: flex;
    flex-direction: column;
    background: var(--card-bg);
    border: 1px solid var(--line-divider);
    border-radius: var(--radius-2xl);
    box-shadow: var(--shadow-xl);
    overflow: hidden;
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
    padding: 0.75rem;
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }
  .msg {
    display: flex;
    max-width: 88%;
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
  .lock-hint {
    margin: 0;
    font-size: 13px;
    color: var(--content-meta);
    max-width: 240px;
    line-height: 1.6;
  }
  .lock-hint code {
    padding: 1px 5px;
    border-radius: var(--radius-sm);
    background: var(--inline-code-bg);
    color: var(--inline-code-color);
    font-size: 12px;
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
  .send-btn {
    flex-shrink: 0;
    height: 36px;
    padding: 0 1rem;
    border: none;
    border-radius: var(--radius-full);
    background: var(--primary);
    color: oklch(1 0 0);
    font-size: 14px;
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
  html.dark .agent-toast.error {
    background: oklch(0.3 0.08 20);
    color: oklch(0.85 0.12 20);
    border-color: oklch(0.45 0.1 20);
  }
  html.dark .agent-toast.warning {
    background: oklch(0.32 0.08 70);
    color: oklch(0.88 0.1 70);
    border-color: oklch(0.45 0.1 70);
  }
  html.dark .agent-toast.success {
    background: oklch(0.32 0.08 150);
    color: oklch(0.88 0.1 150);
    border-color: oklch(0.45 0.1 150);
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
    .agent-panel {
      right: 1rem;
      left: 1rem;
      width: auto;
      height: min(560px, calc(100vh - 2rem));
    }
    .agent-toast {
      right: 1rem;
      bottom: 5rem;
      left: 1rem;
      max-width: none;
    }
  }
</style>
