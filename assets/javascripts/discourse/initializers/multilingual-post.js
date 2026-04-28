import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import I18n from "I18n";

const TIER1 = ["ja", "en", "ko", "de", "es", "zh-CN", "zh-TW", "fr"];
const FLAG_OK = ["ja", "ko", "de", "pl", "vi", "id"];
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
  const flag = FLAG_OK.includes(locale) ? ` ${FLAG_EMOJI[locale]}` : "";
  return `${code} ${native}${flag}`;
}

function isInteractiveTarget(node) {
  if (!node) return false;
  const interactive = ["A", "IMG", "BUTTON", "INPUT", "TEXTAREA", "SELECT"];
  let cur = node;
  while (cur && cur !== document.body) {
    if (interactive.includes(cur.tagName)) return true;
    if (cur.classList && cur.classList.contains("mention")) return true;
    cur = cur.parentNode;
  }
  return false;
}

function togglePost(article) {
  const mode = article.dataset.currentMode;
  const body = article.querySelector(".cooked");
  if (!body) return;

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
  if (!badge) return;
  const mode = article.dataset.currentMode;
  const note = badge.querySelector(".mp-mode-note");
  if (!note) return;
  note.textContent =
    mode === "translated"
      ? I18n.t("multilingual_post.origin_badge.viewing_translation")
      : I18n.t("multilingual_post.origin_badge.viewing_original");
}

function decoratePost(post, helper) {
  const article = helper.getModel
    ? document.querySelector(`article[data-post-id="${post.id}"]`)
    : null;
  if (!article) return;

  const sourceLocale = post.source_locale;
  const translation = post.translation;

  if (!sourceLocale) return;

  // Source matches viewer → no badge, no toggle.
  const viewerLocale = window.I18n?.locale || (post.user && post.user.locale);
  if (sourceLocale === viewerLocale) {
    article.dataset.translatable = "false";
    return;
  }

  // Initial render: prefer translation if completed.
  const cookedBody = article.querySelector(".cooked");
  if (translation && translation.cooked && translation.status === "completed") {
    article.dataset.originalCooked = cookedBody.innerHTML;
    article.dataset.translatedCooked = translation.cooked;
    cookedBody.innerHTML = translation.cooked;
    article.dataset.currentMode = "translated";
  } else {
    article.dataset.currentMode = "original";
  }

  ensureBadge(article, sourceLocale, translation);

  if (article.dataset.translateBound !== "1") {
    article.dataset.translateBound = "1";
    article.addEventListener("click", (e) => {
      if (isInteractiveTarget(e.target)) return;
      if (article.dataset.translatable === "false") return;
      if (!article.dataset.translatedCooked) return;
      togglePost(article);
    });
  }
}

function ensureBadge(article, sourceLocale, translation) {
  const header = article.querySelector(".topic-meta-data, .topic-avatar");
  if (!header) return;
  let badge = article.querySelector(".mp-origin-badge");
  if (!badge) {
    badge = document.createElement("span");
    badge.className = "mp-origin-badge";
    header.appendChild(badge);
  }
  const note = document.createElement("span");
  note.className = "mp-mode-note";
  if (translation && translation.status === "completed") {
    note.textContent = I18n.t("multilingual_post.origin_badge.viewing_translation");
  } else if (translation && translation.status === "pending") {
    note.textContent = I18n.t("multilingual_post.origin_badge.translating");
  } else {
    note.textContent = "";
  }
  badge.innerHTML = `<span class="mp-origin-code">${badgeFor(sourceLocale)}</span> `;
  badge.appendChild(note);
}

function bindMessageBus(api) {
  const bus = api.container.lookup("service:message-bus");
  if (!bus) return;

  api.onPageChange(() => {
    document
      .querySelectorAll("article[data-post-id]")
      .forEach((article) => {
        const postId = article.dataset.postId;
        if (article.dataset.mbBound === "1") return;
        article.dataset.mbBound = "1";
        bus.subscribe(`/post-translation/${postId}`, (data) => {
          const viewerLocale = window.I18n?.locale;
          if (data.locale !== viewerLocale) return;
          article.dataset.translatedCooked = data.cooked;
          if (article.dataset.currentMode === "translated") {
            article.querySelector(".cooked").innerHTML = data.cooked;
          }
          updateBadgeMode(article);
        });
      });
  });
}

export default {
  name: "multilingual-post",

  initialize(container) {
    withPluginApi("1.13.0", (api) => {
      api.includePostAttributes("translation", "source_locale");
      api.decorateWidget("post-contents:after", () => {});
      api.decorateCookedElement(
        (cooked, helper) => {
          if (!helper) return;
          const post = helper.getModel?.();
          if (!post) return;
          // Defer to next frame so the DOM is finalized.
          requestAnimationFrame(() => decoratePost(post, helper));
        },
        { id: "multilingual-post-decorator", onlyStream: true }
      );

      bindMessageBus(api);
    });
  },
};
