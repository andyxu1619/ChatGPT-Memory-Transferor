/*
  Run this in the browser console on https://chatgpt.com while logged in
  as account A. It creates public anonymous share links for your visible
  and archived conversations, then downloads JSON and CSV reports.

  It uses only same-origin ChatGPT endpoints from your current browser
  session. It does not send data to any third-party server.
*/

(async () => {
  const CONFIG = {
    includeVisible: true,
    includeArchived: true,
    isAnonymous: true,
    makePublic: true,
    pageLimit: 100,
    delayMs: 1200,
    retryLimit: 5,
    // First run: keep this at 5 to verify the B-account import behavior.
    // After the test works, change it to Infinity to process everything.
    maxConversations: 5
  };

  const startedAt = new Date();
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const seenIds = new Set();

  function timestampForFile(date = new Date()) {
    return date.toISOString().replace(/[:.]/g, "-").replace("T", "_").slice(0, 19);
  }

  function safeText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  function csvCell(value) {
    const text = String(value ?? "");
    return `"${text.replace(/"/g, '""')}"`;
  }

  function downloadFile(filename, content, type) {
    const blob = new Blob([content], { type });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  }

  async function getAccessToken() {
    async function readSession(url) {
      const response = await fetch(url, {
        credentials: "include",
        headers: { accept: "application/json" }
      });
      if (!response.ok) return { ok: false, status: response.status };
      return { ok: true, session: await response.json() };
    }

    let result = await readSession("/api/auth/session");
    if (!result.ok) {
      result = await readSession("/api/auth/session?refresh=true&reason=gptsync_account_a_export");
    }
    for (let attempt = 0; !result.ok && attempt < 2; attempt += 1) {
      await sleep(CONFIG.delayMs * (attempt + 1));
      result = await readSession("/api/auth/session?refresh=true&reason=gptsync_account_a_export_retry");
    }
    if (!result.ok) {
      throw new Error(`Cannot read ChatGPT session: HTTP ${result.status}`);
    }

    const session = result.session;
    if (!session?.accessToken) {
      throw new Error("No accessToken found. Confirm this tab is logged in to account A.");
    }

    return session.accessToken;
  }

  const accessToken = await getAccessToken();

  async function api(path, options = {}, attempt = 0) {
    const headers = {
      accept: "application/json",
      "content-type": "application/json",
      authorization: `Bearer ${accessToken}`,
      ...(options.headers || {})
    };

    const response = await fetch(path, {
      credentials: "include",
      ...options,
      headers
    });

    const text = await response.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }

    if ((response.status === 429 || response.status >= 500) && attempt < CONFIG.retryLimit) {
      const waitMs = CONFIG.delayMs * Math.pow(2, attempt);
      console.warn(`[retry ${attempt + 1}] ${path} -> HTTP ${response.status}; waiting ${waitMs}ms`);
      await sleep(waitMs);
      return api(path, options, attempt + 1);
    }

    if (!response.ok) {
      const message = typeof data === "string" ? data.slice(0, 500) : JSON.stringify(data).slice(0, 500);
      throw new Error(`HTTP ${response.status} ${response.statusText}: ${message}`);
    }

    return data;
  }

  async function listConversations({ archived }) {
    const output = [];
    let offset = 0;
    let total = Infinity;
    const source = archived ? "archived" : "visible";

    while (offset < total) {
      const params = new URLSearchParams({
        offset: String(offset),
        limit: String(CONFIG.pageLimit),
        order: "updated"
      });
      if (archived) params.set("is_archived", "true");

      const page = await api(`/backend-api/conversations?${params.toString()}`, {
        method: "GET"
      });

      const items = Array.isArray(page?.items) ? page.items : [];
      total = Number.isFinite(page?.total) ? page.total : offset + items.length;

      for (const item of items) {
        if (!item?.id || seenIds.has(item.id)) continue;
        seenIds.add(item.id);
        output.push({ ...item, source });
      }

      console.log(`[list:${source}] ${Math.min(offset + items.length, total)} / ${total}`);
      if (!items.length) break;
      offset += items.length;
      await sleep(250);
    }

    return output;
  }

  function pickLatestLeafFromMapping(mapping) {
    if (!mapping || typeof mapping !== "object") return null;

    const nodes = Object.entries(mapping)
      .map(([id, node]) => ({
        id,
        createTime: Number(node?.message?.create_time || 0),
        hasMessage: Boolean(node?.message),
        childCount: Array.isArray(node?.children) ? node.children.length : 0
      }))
      .filter((node) => node.hasMessage);

    const leaves = nodes.filter((node) => node.childCount === 0);
    const candidates = leaves.length ? leaves : nodes;
    candidates.sort((a, b) => b.createTime - a.createTime);
    return candidates[0]?.id || null;
  }

  async function publishShare(conversation) {
    const detail = await api(`/backend-api/conversation/${conversation.id}`, { method: "GET" });
    const title = safeText(detail?.title || conversation.title || "Untitled conversation");
    const currentNodeId =
      detail?.current_node ||
      detail?.current_node_id ||
      detail?.moderation_results?.current_node_id ||
      pickLatestLeafFromMapping(detail?.mapping);

    if (!currentNodeId) {
      throw new Error("Cannot determine current_node_id for this conversation.");
    }

    const createPayload = {
      conversation_id: conversation.id,
      current_node_id: currentNodeId,
      is_anonymous: CONFIG.isAnonymous
    };

    const created = await api("/backend-api/share/create", {
      method: "POST",
      body: JSON.stringify(createPayload)
    });

    let shareUrl =
      created?.share_url ||
      created?.url ||
      (created?.share_id ? `https://chatgpt.com/share/${created.share_id}` : "");

    let patchOk = false;
    let patchError = "";

    if (CONFIG.makePublic) {
      const patchPayload = {
        share_id: created?.share_id,
        highlighted_message_id: null,
        is_anonymous: CONFIG.isAnonymous,
        is_public: true,
        is_visible: true,
        title,
        current_node_id: currentNodeId
      };

      const patchIds = Array.from(new Set([
        conversation.id,
        created?.conversation_id,
        created?.share_id
      ].filter(Boolean)));

      for (const patchId of patchIds) {
        try {
          const patched = await api(`/backend-api/share/${patchId}`, {
            method: "PATCH",
            body: JSON.stringify(patchPayload)
          });
          shareUrl =
            patched?.share_url ||
            patched?.url ||
            shareUrl ||
            (patched?.share_id ? `https://chatgpt.com/share/${patched.share_id}` : "");
          patchOk = true;
          break;
        } catch (error) {
          patchError = String(error?.message || error);
        }
      }
    }

    return {
      status: "ok",
      id: conversation.id,
      title,
      source: conversation.source,
      create_time: detail?.create_time || conversation.create_time || null,
      update_time: detail?.update_time || conversation.update_time || null,
      current_node_id: currentNodeId,
      share_id: created?.share_id || null,
      share_url: shareUrl,
      already_exists: Boolean(created?.already_exists),
      patch_public_ok: patchOk,
      patch_error: patchError
    };
  }

  console.log("[start] Listing conversations from account A...");

  const conversations = [];
  if (CONFIG.includeVisible) {
    conversations.push(...await listConversations({ archived: false }));
  }
  if (CONFIG.includeArchived) {
    try {
      conversations.push(...await listConversations({ archived: true }));
    } catch (error) {
      console.warn("[archived] Could not list archived conversations:", error);
    }
  }

  const limited = conversations.slice(0, CONFIG.maxConversations);
  console.log(`[start] Creating share links for ${limited.length} conversations...`);

  const results = [];
  for (let index = 0; index < limited.length; index += 1) {
    const conversation = limited[index];
    const label = `${index + 1}/${limited.length} ${safeText(conversation.title || conversation.id)}`;

    try {
      console.log(`[share] ${label}`);
      const result = await publishShare(conversation);
      results.push(result);
      console.log(`[ok] ${result.share_url}`);
    } catch (error) {
      const failed = {
        status: "error",
        id: conversation.id,
        title: safeText(conversation.title || "Untitled conversation"),
        source: conversation.source,
        create_time: conversation.create_time || null,
        update_time: conversation.update_time || null,
        error: String(error?.message || error)
      };
      results.push(failed);
      console.error(`[error] ${label}`, error);
    }

    await sleep(CONFIG.delayMs);
  }

  const finishedAt = new Date();
  const okCount = results.filter((item) => item.status === "ok" && item.share_url).length;
  const errorCount = results.length - okCount;
  const report = {
    schema: "chatgpt-shared-link-migration-v1",
    generated_at: finishedAt.toISOString(),
    account_hint: "account A in current browser session",
    config: CONFIG,
    summary: {
      listed: conversations.length,
      processed: results.length,
      ok: okCount,
      errors: errorCount,
      elapsed_seconds: Math.round((finishedAt - startedAt) / 1000)
    },
    results
  };

  const stamp = timestampForFile(finishedAt);
  const jsonName = `chatgpt-account-a-share-links_${stamp}.json`;
  const csvName = `chatgpt-account-a-share-links_${stamp}.csv`;
  const csvRows = [
    ["status", "source", "title", "share_url", "id", "share_id", "create_time", "update_time", "error"].join(","),
    ...results.map((row) => [
      row.status,
      row.source,
      row.title,
      row.share_url,
      row.id,
      row.share_id,
      row.create_time,
      row.update_time,
      row.error
    ].map(csvCell).join(","))
  ].join("\n");

  downloadFile(jsonName, JSON.stringify(report, null, 2), "application/json;charset=utf-8");
  downloadFile(csvName, csvRows, "text/csv;charset=utf-8");

  console.log(`[done] ${okCount} links created, ${errorCount} errors.`);
  console.log(`[done] Downloaded ${jsonName} and ${csvName}.`);
})();
