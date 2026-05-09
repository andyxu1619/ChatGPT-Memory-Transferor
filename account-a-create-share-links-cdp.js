(async () => {
  const CONFIG = {
    includeVisible: true,
    includeArchived: true,
    isAnonymous: true,
    makePublic: true,
    pageLimit: 100,
    delayMs: 1200,
    retryLimit: 5,
    requestTimeoutMs: 45000,
    dryRun: false,
    skipConversations: 0,
    maxConversations: Number.POSITIVE_INFINITY
  };

  const EXTERNAL_OPTIONS = window.__CHATGPT_SHARE_EXPORT_OPTIONS__ || {};
  if (EXTERNAL_OPTIONS.dryRun) CONFIG.dryRun = true;
  if (Number.isFinite(EXTERNAL_OPTIONS.maxConversations) && EXTERNAL_OPTIONS.maxConversations > 0) {
    CONFIG.maxConversations = EXTERNAL_OPTIONS.maxConversations;
  }
  if (Number.isFinite(EXTERNAL_OPTIONS.skipConversations) && EXTERNAL_OPTIONS.skipConversations > 0) {
    CONFIG.skipConversations = EXTERNAL_OPTIONS.skipConversations;
  }

  const startedAt = new Date();
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const seenConversationIds = new Set();
  const projectById = new Map();
  const projectByConversationId = new Map();
  const projectConversationById = new Map();

  function safeText(value) {
    return String(value ?? "").replace(/\s+/g, " ").trim();
  }

  function getValueAtPath(value, path) {
    let current = value;
    for (const key of path) {
      if (!current || typeof current !== "object") return null;
      current = current[key];
    }
    return current ?? null;
  }

  function firstNonEmpty(...values) {
    for (const value of values) {
      const text = safeText(value);
      if (text) return text;
    }
    return "";
  }

  async function getAccessToken() {
    const response = await fetch("/api/auth/session", {
      credentials: "include",
      headers: { accept: "application/json" }
    });

    if (!response.ok) {
      throw new Error(`Cannot read ChatGPT session: HTTP ${response.status}`);
    }

    const session = await response.json();
    if (!session?.accessToken) {
      throw new Error("No accessToken found. Confirm this browser window is logged in to account A.");
    }

    return session.accessToken;
  }

  console.log("[start] Reading ChatGPT session...");
  const accessToken = await getAccessToken();
  console.log("[ok] ChatGPT session token detected.");

  async function api(path, options = {}, attempt = 0) {
    const headers = {
      accept: "application/json",
      "content-type": "application/json",
      authorization: `Bearer ${accessToken}`,
      ...(options.headers || {})
    };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), CONFIG.requestTimeoutMs);
    let response;

    try {
      response = await fetch(path, {
        credentials: "include",
        ...options,
        headers,
        signal: controller.signal
      });
    } catch (error) {
      clearTimeout(timer);
      if (attempt < CONFIG.retryLimit) {
        const waitMs = CONFIG.delayMs * Math.pow(2, attempt);
        console.warn(`[retry ${attempt + 1}] ${path} -> ${String(error?.message || error)}; waiting ${waitMs}ms`);
        await sleep(waitMs);
        return api(path, options, attempt + 1);
      }
      throw new Error(`Network error on ${path}: ${String(error?.message || error)}`);
    } finally {
      clearTimeout(timer);
    }

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

  function asArray(payload) {
    if (Array.isArray(payload)) return payload;
    for (const key of ["items", "projects", "gizmos", "data", "results"]) {
      if (Array.isArray(payload?.[key])) return payload[key];
    }
    return [];
  }

  function unwrapProject(project) {
    return project?.gizmo?.gizmo || project?.gizmo || project;
  }

  function normalizeFile(file) {
    if (!file || typeof file !== "object") return null;
    const fileId = firstNonEmpty(file.file_id, file.id);
    const name = firstNonEmpty(file.name, file.file_name, file.filename);
    if (!fileId && !name) return null;

    return {
      id: firstNonEmpty(file.id, fileId),
      file_id: fileId,
      name,
      type: firstNonEmpty(file.type, file.mime_type, file.content_type),
      size: Number.isFinite(Number(file.size)) ? Number(file.size) : null,
      created_at: file.created_at || null,
      last_modified: file.last_modified || null,
      location: firstNonEmpty(file.location),
      file_response_type: firstNonEmpty(file.file_response_type),
      file_size_tokens: file.file_size_tokens ?? null
    };
  }

  function mergeFiles(existingFiles, incomingFiles) {
    const byKey = new Map();
    for (const file of [...(existingFiles || []), ...(incomingFiles || [])]) {
      const normalized = normalizeFile(file);
      if (!normalized) continue;
      const key = normalized.file_id || normalized.id || normalized.name;
      if (!byKey.has(key)) {
        byKey.set(key, normalized);
      } else {
        byKey.set(key, { ...byKey.get(key), ...normalized });
      }
    }
    return Array.from(byKey.values());
  }

  function recordProject(project, source) {
    const resource = project?.gizmo?.gizmo ? project.gizmo : project;
    const rawProject = unwrapProject(project);
    if (!rawProject || typeof rawProject !== "object") return null;

    const id = firstNonEmpty(
      rawProject.id,
      rawProject.project_id,
      rawProject.gizmo_id,
      rawProject.conversation_template_id
    );
    if (!id) return null;

    const display = rawProject.display || rawProject.metadata?.display || {};
    const name = firstNonEmpty(
      rawProject.name,
      rawProject.title,
      rawProject.display_name,
      display.name,
      display.title,
      getValueAtPath(rawProject, ["metadata", "name"]),
      getValueAtPath(rawProject, ["metadata", "title"])
    ) || id;

    const existing = projectById.get(id) || {};
    const incomingFiles = mergeFiles([], [
      ...asArray(resource?.files),
      ...asArray(project?.files),
      ...asArray(rawProject?.files)
    ]);
    const conversationItems = asArray(project?.conversations);
    const normalized = {
      id,
      name,
      description: firstNonEmpty(display.description, rawProject.description, existing.description),
      instructions: firstNonEmpty(rawProject.instructions, existing.instructions),
      emoji: firstNonEmpty(display.emoji, existing.emoji),
      theme: firstNonEmpty(display.theme, existing.theme),
      profile_pic_id: firstNonEmpty(display.profile_pic_id, existing.profile_pic_id),
      profile_picture_url: firstNonEmpty(display.profile_picture_url, existing.profile_picture_url),
      prompt_starters: Array.isArray(display.prompt_starters) ? display.prompt_starters : (existing.prompt_starters || []),
      memory_scope: firstNonEmpty(rawProject.memory_scope, existing.memory_scope),
      training_disabled: rawProject.training_disabled ?? existing.training_disabled ?? null,
      use_injest_path: rawProject.use_injest_path ?? existing.use_injest_path ?? null,
      is_archived: rawProject.is_archived ?? existing.is_archived ?? false,
      conversation_count_hint: Math.max(
        Number(existing.conversation_count_hint || 0),
        Number.isFinite(Number(project?.conversations?.total)) ? Number(project.conversations.total) : conversationItems.length
      ),
      sources: Array.from(new Set([...(existing.sources || []), source].filter(Boolean))),
      files: mergeFiles(existing.files || [], incomingFiles)
    };
    projectById.set(id, normalized);
    return normalized;
  }

  function rememberConversationProject(conversationId, project) {
    if (!conversationId || !project?.id) return;
    projectByConversationId.set(conversationId, project);
  }

  function rememberProjectConversation(conversation, project, source) {
    const conversationId = getConversationId(conversation);
    if (!conversationId || !project?.id) return;

    rememberConversationProject(conversationId, project);
    projectConversationById.set(conversationId, {
      ...conversation,
      id: conversationId,
      source: "project",
      project_id: project.id,
      gizmo_id: project.id,
      conversation_template_id: project.id,
      project_name_hint: project.name,
      project_source_hint: source
    });
  }

  function getConversationId(item) {
    return firstNonEmpty(
      item?.id,
      item?.conversation_id,
      item?.conversationId,
      getValueAtPath(item, ["conversation", "id"])
    );
  }

  async function listProjectConversations(project) {
    const endpointTemplates = [
      (id, offset) => `/backend-api/gizmos/${encodeURIComponent(id)}/conversations?offset=${offset}&limit=${CONFIG.pageLimit}&order=updated`,
      (id, offset) => `/backend-api/projects/${encodeURIComponent(id)}/conversations?offset=${offset}&limit=${CONFIG.pageLimit}&order=updated`,
      (id, offset) => `/backend-api/gizmos/${encodeURIComponent(id)}/conversations?cursor=${offset}`
    ];

    for (const makePath of endpointTemplates) {
      let offset = 0;
      let total = Infinity;
      let foundAny = false;

      try {
        while (offset < total) {
          const page = await api(makePath(project.id, offset), { method: "GET" });
          const items = asArray(page);
          total = Number.isFinite(page?.total) ? page.total : offset + items.length;

          for (const item of items) {
            const conversationId = getConversationId(item);
            if (conversationId) {
              rememberProjectConversation(item, project, "project-conversation-list");
              foundAny = true;
            }
          }

          if (!items.length) break;
          offset += items.length;
          await sleep(150);
        }

        if (foundAny) return true;
      } catch {
        // ChatGPT has changed these internal paths before. Keep exporting even
        // when project conversation listing is unavailable.
      }
    }

    return false;
  }

  async function discoverProjects() {
    try {
      let cursor = null;
      for (let pageIndex = 0; pageIndex < 20; pageIndex += 1) {
        const query = new URLSearchParams({
          owned_only: "true",
          conversations_per_gizmo: "5",
          limit: "50"
        });
        if (cursor) query.set("cursor", cursor);

        const payload = await api(`/backend-api/gizmos/snorlax/sidebar?${query.toString()}`, { method: "GET" });
        for (const item of asArray(payload)) {
          const project = recordProject(item, "gizmos/snorlax/sidebar");
          for (const conversation of asArray(item?.conversations)) {
            const conversationId = getConversationId(conversation);
            if (conversationId && project) {
              rememberProjectConversation(conversation, project, "gizmos/snorlax/sidebar");
            }
          }
        }

        cursor = payload?.cursor || null;
        if (!cursor) break;
      }
    } catch (error) {
      console.warn(`[project] paged snorlax sidebar unavailable: ${String(error?.message || error)}`);
    }

    const projectEndpoints = [
      "/backend-api/projects",
      "/backend-api/gizmos/discovery/mine"
    ];

    for (const endpoint of projectEndpoints) {
      try {
        const payload = await api(endpoint, { method: "GET" });
        for (const item of asArray(payload)) {
          const project = recordProject(item, endpoint);
          for (const conversation of asArray(item?.conversations)) {
            const conversationId = getConversationId(conversation);
            if (conversationId && project) {
              rememberProjectConversation(conversation, project, endpoint);
            }
          }
        }
      } catch (error) {
        console.warn(`[project] ${endpoint} unavailable: ${String(error?.message || error)}`);
      }
    }

    const projects = Array.from(projectById.values());
    console.log(`[project] discovered ${projects.length} project/custom-GPT records`);

    for (const project of projects) {
      try {
        const detail = await api(`/backend-api/gizmos/${encodeURIComponent(project.id)}?include_files=true`, { method: "GET" });
        recordProject(detail, "gizmo-detail");
      } catch (error) {
        console.warn(`[project] detail unavailable for ${project.name}: ${String(error?.message || error)}`);
      }
      await listProjectConversations(project);
    }

    console.log(`[project] mapped ${projectByConversationId.size} conversations to projects`);
  }

  function resolveProject(conversation, detail) {
    const directProject = projectByConversationId.get(conversation.id) || projectByConversationId.get(detail?.id);
    if (directProject) {
      return {
        project_id: directProject.id,
        project_name: directProject.name,
        project_source: "project-conversation-list"
      };
    }

    const idCandidates = [
      getValueAtPath(detail, ["metadata", "project_id"]),
      getValueAtPath(detail, ["metadata", "project", "id"]),
      getValueAtPath(detail, ["metadata", "gizmo_id"]),
      getValueAtPath(detail, ["metadata", "conversation_template_id"]),
      detail?.project_id,
      detail?.gizmo_id,
      detail?.conversation_template_id,
      conversation?.project_id,
      conversation?.gizmo_id,
      conversation?.conversation_template_id
    ].map(safeText).filter(Boolean);

    for (const id of idCandidates) {
      const known = projectById.get(id);
      if (known) {
        return {
          project_id: known.id,
          project_name: known.name,
          project_source: "metadata-id"
        };
      }
    }

    const metadataName = firstNonEmpty(
      getValueAtPath(detail, ["metadata", "project", "name"]),
      getValueAtPath(detail, ["metadata", "project", "title"]),
      getValueAtPath(detail, ["metadata", "gizmo", "name"]),
      getValueAtPath(detail, ["metadata", "gizmo", "title"]),
      getValueAtPath(conversation, ["metadata", "project", "name"]),
      getValueAtPath(conversation, ["metadata", "project", "title"]),
      getValueAtPath(conversation, ["metadata", "gizmo", "name"]),
      getValueAtPath(conversation, ["metadata", "gizmo", "title"])
    );

    if (metadataName) {
      return {
        project_id: firstNonEmpty(...idCandidates),
        project_name: metadataName,
        project_source: "metadata-name"
      };
    }

    return {
      project_id: firstNonEmpty(...idCandidates),
      project_name: "未归属项目",
      project_source: idCandidates.length ? "unknown-id" : "none"
    };
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

      const items = asArray(page);
      total = Number.isFinite(page?.total) ? page.total : offset + items.length;

      for (const item of items) {
        if (!item?.id || seenConversationIds.has(item.id)) continue;
        seenConversationIds.add(item.id);
        output.push({ ...item, source });
      }

      console.log(`[list:${source}] ${Math.min(offset + items.length, total)} / ${total}`);
      if (!items.length) break;
      offset += items.length;
      await sleep(250);
    }

    return output;
  }

  function listKnownProjectConversations() {
    const output = [];

    for (const conversation of projectConversationById.values()) {
      if (!conversation?.id || seenConversationIds.has(conversation.id)) continue;
      seenConversationIds.add(conversation.id);
      output.push(conversation);
    }

    console.log(`[list:project] ${output.length} new / ${projectConversationById.size} mapped`);
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

    const project = resolveProject(conversation, detail);

    if (CONFIG.dryRun) {
      return {
        status: "dry-run",
        id: conversation.id,
        title,
        project_name: project.project_name,
        project_id: project.project_id,
        project_source: project.project_source,
        source: conversation.source,
        create_time: detail?.create_time || conversation.create_time || null,
        update_time: detail?.update_time || conversation.update_time || null,
        current_node_id: currentNodeId,
        share_id: null,
        share_url: "",
        already_exists: false,
        patch_public_ok: false,
        patch_error: ""
      };
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
      project_name: project.project_name,
      project_id: project.project_id,
      project_source: project.project_source,
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

  if (CONFIG.dryRun) {
    console.log("[mode] Dry run: no shared links will be created.");
  }

  console.log("[start] Discovering project metadata...");
  await discoverProjects();

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
  conversations.push(...listKnownProjectConversations());

  const candidates = conversations.slice(CONFIG.skipConversations);
  const limited = candidates.slice(0, CONFIG.maxConversations);
  if (CONFIG.skipConversations > 0) {
    console.log(`[start] Skipping first ${CONFIG.skipConversations} conversations for this run.`);
  }
  console.log(`[start] Creating share links for ${limited.length} conversations...`);

  const results = [];
  for (let index = 0; index < limited.length; index += 1) {
    const conversation = limited[index];
    const label = `${index + 1}/${limited.length} ${safeText(conversation.title || conversation.id)}`;

    try {
      console.log(`[share] ${label}`);
      const result = await publishShare(conversation);
      results.push(result);
      console.log(`[ok] ${result.project_name} | ${result.share_url}`);
    } catch (error) {
      const failedProject = {
        project_name: "未知",
        project_id: "",
        project_source: "error-before-detail"
      };
      const failed = {
        status: "error",
        id: conversation.id,
        title: safeText(conversation.title || "Untitled conversation"),
        project_name: failedProject.project_name,
        project_id: failedProject.project_id,
        project_source: failedProject.project_source,
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
  const dryRunCount = results.filter((item) => item.status === "dry-run").length;
  const errorCount = results.filter((item) => item.status === "error").length;
  const projectRecords = Array.from(projectById.values());
  const projects = projectRecords.filter((project) => String(project.id || "").startsWith("g-p-")).map((project) => ({
    ...project,
    file_count: Array.isArray(project.files) ? project.files.length : 0,
    mapped_conversation_count: Array.from(projectByConversationId.values())
      .filter((mappedProject) => mappedProject?.id === project.id).length
  }));
  const projectFileCount = projects.reduce((count, project) => count + (project.file_count || 0), 0);
  const projectSummary = results.reduce((summary, item) => {
    const name = item.project_name || "未知";
    summary[name] = (summary[name] || 0) + 1;
    return summary;
  }, {});

  console.log(`[done] ${okCount} links created, ${errorCount} errors.`);

  return {
    schema: "chatgpt-shared-link-migration-v2",
    generated_at: finishedAt.toISOString(),
    account_hint: "account A in current browser session",
    config: {
      ...CONFIG,
      maxConversations: Number.isFinite(CONFIG.maxConversations) ? CONFIG.maxConversations : "all"
    },
    summary: {
      listed: conversations.length,
      processed: results.length,
      ok: okCount,
      dry_run: dryRunCount,
      errors: errorCount,
      project_or_gizmo_records_discovered: projectById.size,
      projects_discovered: projects.length,
      project_conversation_mappings: projectByConversationId.size,
      projects_with_files: projects.filter((project) => project.file_count > 0).length,
      project_files: projectFileCount,
      elapsed_seconds: Math.round((finishedAt - startedAt) / 1000),
      by_project: projectSummary
    },
    projects,
    results
  };
})();
