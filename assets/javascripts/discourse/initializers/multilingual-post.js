import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

/**
 * Tier 1 + Tier 2 native-script labels — kept in JS so we can render badges
 * client-side without an extra round trip. Mirrors plugin.rb's
 * MultilingualPost::TIER1_LOCALES + TIER2_LOCALES.
 */
const NATIVE_LABEL = {
  ja: "日本語",
  en: "English",
  ko: "한국어",
  de: "Deutsch",
  es: "Español",
  "zh-CN": "中文 (简体)",
  "zh-TW": "中文 (繁體)",
  fr: "Français",
  pt: "Português",
  it: "Italiano",
  ru: "Русский",
  bn: "বাংলা",
  vi: "Tiếng Việt",
  id: "Bahasa Indonesia",
  pl: "Polski",
};

/**
 * Locales where a flag is OK alongside the native-script label. Mirrors
 * MultilingualPost::FLAG_OK_LOCALES in plugin.rb. PLAN.md §「国旗を使わない理由」
 * documents why en/es/fr/zh-CN/zh-TW/pt/it/ru/bn never get a flag.
 */
const FLAG_OK = new Set(["ja", "ko", "de", "pl", "vi", "id"]);
const FLAG_EMOJI = {
  ja: "🇯🇵",
  ko: "🇰🇷",
  de: "🇩🇪",
  pl: "🇵🇱",
  vi: "🇻🇳",
  id: "🇮🇩",
};

function badgeFor(locale) {
  const code = locale.toUpperCase();
  const native = NATIVE_LABEL[locale] || locale;
  const flag = FLAG_OK.has(locale) ? ` ${FLAG_EMOJI[locale]}` : "";
  return `${code} ${native}${flag}`;
}

/**
 * Don't trigger the original/translated toggle on clicks inside links,
 * images, mentions, or form controls — those have their own click semantics.
 */
function isInteractiveTarget(node) {
  if (!node) {
    return false;
  }
  const interactive = ["A", "IMG", "BUTTON", "INPUT", "TEXTAREA", "SELECT"];
  let cur = node;
  while (cur && cur !== document.body) {
    if (interactive.includes(cur.tagName)) {
      return true;
    }
    if (cur.classList?.contains("mention")) {
      return true;
    }
    cur = cur.parentNode;
  }
  return false;
}

function togglePost(article) {
  const mode = article.dataset.currentMode;
  const body = article.querySelector(".cooked");
  if (!body) {
    return;
  }

  if (mode === "translated") {
    body.innerHTML = article.dataset.originalCooked || body.innerHTML;
    article.dataset.currentMode = "original";
  } else {
    body.innerHTML = article.dataset.translatedCooked || body.innerHTML;
    article.dataset.currentMode = "translated";
  }
  updateBadgeMode(article);
}

function updateBadgeMode(article) {
  const badge = article.querySelector(".mp-origin-badge");
  if (!badge) {
    return;
  }
  const mode = article.dataset.currentMode;
  const note = badge.querySelector(".mp-mode-note");
  if (!note) {
    return;
  }
  note.textContent =
    mode === "translated"
      ? i18n("multilingual_post.origin_badge.viewing_translation")
      : i18n("multilingual_post.origin_badge.viewing_original");
}

/**
 * Apply translation state to a single rendered <article>. Idempotent —
 * decorateCookedElement may fire multiple times for the same post (e.g. after
 * a stream refresh), so we guard the click binding with `data-translate-bound`.
 */
function decoratePost(post, helper) {
  if (!post || !helper?.getModel) {
    return;
  }
  const article = document.querySelector(
    `article[data-post-id="${post.id}"]`
  );
  if (!article) {
    return;
  }

  const sourceLocale = post.source_locale;
  if (!sourceLocale) {
    return;
  }
  const translation = post.translation;

  // Source matches viewer → no badge, no toggle. We still mark the article so
  // the click handler (if already bound) bails out fast.
  const viewerLocale = window.I18n?.currentLocale?.() || window.I18n?.locale;
  if (sourceLocale === viewerLocale) {
    article.dataset.translatable = "false";
    return;
  }

  const cookedBody = article.querySelector(".cooked");
  if (!cookedBody) {
    return;
  }

  // Initial render: prefer translation when completed.
  if (translation?.cooked && translation.status === "completed") {
    article.dataset.originalCooked = cookedBody.innerHTML;
    article.dataset.translatedCooked = translation.cooked;
    cookedBody.innerHTML = translation.cooked;
    article.dataset.currentMode = "translated";
  } else if (!article.dataset.currentMode) {
    article.dataset.currentMode = "original";
  }

  ensureBadge(article, sourceLocale, translation);

  if (article.dataset.translateBound !== "1") {
    article.dataset.translateBound = "1";
    article.addEventListener("click", (e) => {
      if (isInteractiveTarget(e.target)) {
        return;
      }
      if (article.dataset.translatable === "false") {
        return;
      }
      if (!article.dataset.translatedCooked) {
        return;
      }
      togglePost(article);
    });
  }
}

function ensureBadge(article, sourceLocale, translation) {
  // Place the badge in the post's meta header so it sits next to the
  // username/timestamp. `topic-meta-data` is the canonical container; we fall
  // back to topic-avatar for the OP slot which has a different DOM shape.
  const header = article.querySelector(".topic-meta-data, .topic-avatar");
  if (!header) {
    return;
  }
  let badge = article.querySelector(".mp-origin-badge");
  if (!badge) {
    badge = document.createElement("span");
    badge.className = "mp-origin-badge";
    badge.setAttribute("role", "note");
    header.appendChild(badge);
  }

  // Rebuild contents in-place rather than replacing nodes — avoids fighting
  // with Discourse's own re-renders that may re-mount the header.
  badge.innerHTML = "";

  const code = document.createElement("span");
  code.className = "mp-origin-code";
  code.textContent = badgeFor(sourceLocale);
  badge.appendChild(code);

  const note = document.createElement("span");
  note.className = "mp-mode-note";
  if (translation?.status === "completed") {
    note.textContent = i18n("multilingual_post.origin_badge.viewing_translation");
  } else if (translation?.status === "pending") {
    note.textContent = i18n("multilingual_post.origin_badge.translating");
  } else {
    note.textContent = "";
  }
  badge.appendChild(note);

  // a11y: make the badge announceable. Use aria-label so screen readers read
  // both the locale name and the current mode in one pass.
  badge.setAttribute(
    "aria-label",
    `${badgeFor(sourceLocale)} ${note.textContent}`.trim()
  );
}

/**
 * Subscribe each visible post to its `/post-translation/:id` MessageBus
 * channel exactly once, and clean up when the post leaves the DOM.
 *
 * Why we track subscriptions in a Map instead of just dataset flags:
 *  - MessageBus.subscribe returns nothing useful for unsubscribing — we have
 *    to pass the same callback reference back to `unsubscribe`.
 *  - On every page change Discourse may swap the post stream entirely; if we
 *    don't unsubscribe the old callbacks they accumulate forever and trigger
 *    on stale articles, leaking memory and (worse) firing innerHTML writes
 *    against detached nodes.
 */
function bindMessageBus(api) {
  const bus = api.container.lookup("service:message-bus");
  if (!bus) {
    return;
  }

  // postId (string) → { channel, callback }
  const subscriptions = new Map();

  function subscribePost(article) {
    const postId = article.dataset.postId;
    if (!postId || subscriptions.has(postId)) {
      return;
    }
    const channel = `/post-translation/${postId}`;
    const callback = (data) => {
      // Re-resolve the article each tick — the original reference may have
      // been replaced by a re-render even if our subscription survived.
      const live = document.querySelector(`article[data-post-id="${postId}"]`);
      if (!live) {
        return;
      }
      const viewerLocale =
        window.I18n?.currentLocale?.() || window.I18n?.locale;
      if (data.locale !== viewerLocale) {
        return;
      }
      live.dataset.translatedCooked = data.cooked;
      if (live.dataset.currentMode === "translated") {
        const body = live.querySelector(".cooked");
        if (body) {
          body.innerHTML = data.cooked;
        }
      }
      updateBadgeMode(live);
    };
    // Pass `-1` as last_id so we only receive *new* messages — without it,
    // every page nav would replay the entire backlog for that channel.
    bus.subscribe(channel, callback, -1);
    subscriptions.set(postId, { channel, callback });
  }

  function reconcileSubscriptions() {
    const liveIds = new Set(
      Array.from(document.querySelectorAll("article[data-post-id]")).map(
        (a) => a.dataset.postId
      )
    );
    // Subscribe to anything new.
    liveIds.forEach((id) => {
      const article = document.querySelector(`article[data-post-id="${id}"]`);
      if (article) {
        subscribePost(article);
      }
    });
    // Unsubscribe anything that's no longer in the DOM. This is the cleanup
    // path that the previous implementation was missing.
    for (const [id, { channel, callback }] of subscriptions.entries()) {
      if (!liveIds.has(id)) {
        bus.unsubscribe(channel, callback);
        subscriptions.delete(id);
      }
    }
  }

  api.onPageChange(reconcileSubscriptions);

  // Also reconcile after the post stream updates (new posts arriving via the
  // existing topic), since onPageChange doesn't fire for in-page additions.
  api.onAppEvent?.("post-stream:refresh", reconcileSubscriptions);
}

export default {
  name: "multilingual-post",

  initialize() {
    withPluginApi("1.13.0", (api) => {
      // Pull translation + source_locale into the Post serializer payload so
      // decorateCookedElement can read them from `helper.getModel()`.
      api.includePostAttributes("translation", "source_locale");

      api.decorateCookedElement(
        (cooked, helper) => {
          if (!helper) {
            return;
          }
          const post = helper.getModel?.();
          if (!post) {
            return;
          }
          // Defer to the next frame so Discourse has finished mounting the
          // article DOM before we query/mutate it.
          requestAnimationFrame(() => decoratePost(post, helper));
        },
        { id: "multilingual-post-decorator", onlyStream: true }
      );

      bindMessageBus(api);
    });
  },
};
