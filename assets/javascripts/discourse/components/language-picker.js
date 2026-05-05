import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

/**
 * All 15 supported locales. Tier 1 first (mirrors PLAN.md ordering — the
 * 7 languages we pre-translate at post time), Tier 2 below (lazy / on-demand).
 *
 * Keep this list in sync with `MultilingualPost::TIER1_LOCALES + TIER2_LOCALES`
 * in plugin.rb. We intentionally render only native-script labels (no flags)
 * for the dropdown — see PLAN.md §「国旗を使わない理由」for why. Flags only
 * appear on the *origin badge* for ja/ko/de/pl/vi/id; the picker stays neutral.
 */
const LOCALES = [
  // Tier 1 — pre-cached on every post
  { code: "ja", label: "日本語", tier: 1 },
  { code: "en", label: "English", tier: 1 },
  { code: "ko", label: "한국어", tier: 1 },
  { code: "de", label: "Deutsch", tier: 1 },
  { code: "es", label: "Español", tier: 1 },
  { code: "zh-CN", label: "中文 (简体)", tier: 1 },
  { code: "zh-TW", label: "中文 (繁體)", tier: 1 },
  { code: "fr", label: "Français", tier: 1 },
  // Tier 2 — selectable, on-demand translation
  { code: "pt", label: "Português", tier: 2 },
  { code: "it", label: "Italiano", tier: 2 },
  { code: "ru", label: "Русский", tier: 2 },
  { code: "bn", label: "বাংলা", tier: 2 },
  { code: "vi", label: "Tiếng Việt", tier: 2 },
  { code: "id", label: "Bahasa Indonesia", tier: 2 },
  { code: "pl", label: "Polski", tier: 2 },
];

export default class LanguagePicker extends Component {
  @service currentUser;
  @service router;

  @tracked open = false;
  @tracked saving = false;

  // Refs for focus management. The button is the trigger we restore focus to
  // when the dropdown closes; the menu is what we close when focus leaves.
  triggerEl = null;
  menuEl = null;

  get currentLocale() {
    return this.currentUser?.locale ?? null;
  }

  get currentLabel() {
    return (
      LOCALES.find((l) => l.code === this.currentLocale)?.label ??
      this.currentLocale ??
      "🌐"
    );
  }

  get locales() {
    return LOCALES;
  }

  @action
  registerTrigger(el) {
    this.triggerEl = el;
  }

  @action
  registerMenu(el) {
    this.menuEl = el;
    // Auto-focus the currently-selected option (or the first) when the menu
    // mounts, so keyboard users land somewhere useful.
    const target =
      el.querySelector(`[data-locale="${this.currentLocale}"]`) ||
      el.querySelector(".mp-language-option");
    target?.focus();
    // Wire up a one-shot outside-click listener while the menu is open.
    // We attach to `mousedown` (not `click`) so the close happens before any
    // focus events from the underlying element fire.
    this._outsideHandler = (event) => {
      if (
        this.menuEl?.contains(event.target) ||
        this.triggerEl?.contains(event.target)
      ) {
        return;
      }
      this.close();
    };
    document.addEventListener("mousedown", this._outsideHandler, true);
  }

  @action
  unregisterMenu() {
    if (this._outsideHandler) {
      document.removeEventListener("mousedown", this._outsideHandler, true);
      this._outsideHandler = null;
    }
    this.menuEl = null;
  }

  @action
  toggle() {
    this.open = !this.open;
  }

  @action
  close() {
    if (!this.open) {
      return;
    }
    this.open = false;
    // Restore focus to the trigger so keyboard users don't get dropped on body.
    this.triggerEl?.focus();
  }

  @action
  onTriggerKeydown(event) {
    // Open with ArrowDown / Enter / Space — standard menu-button pattern.
    if (event.key === "ArrowDown" || event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      this.open = true;
    } else if (event.key === "Escape") {
      this.close();
    }
  }

  @action
  onMenuKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") {
      return;
    }
    event.preventDefault();
    const items = Array.from(
      this.menuEl?.querySelectorAll(".mp-language-option") ?? []
    );
    if (items.length === 0) {
      return;
    }
    const idx = items.indexOf(document.activeElement);
    const next =
      event.key === "ArrowDown"
        ? items[(idx + 1) % items.length]
        : items[(idx - 1 + items.length) % items.length];
    next.focus();
  }

  @action
  async select(code) {
    if (!this.currentUser || this.saving) {
      return;
    }
    this.saving = true;
    try {
      await ajax(`/u/${this.currentUser.username}.json`, {
        type: "PUT",
        data: { locale: code },
      });
      // Avoid `set` (legacy Ember). Mutating the proxied user object directly
      // is enough; the hard reload below rehydrates everything anyway.
      this.currentUser.locale = code;
      this.open = false;
      // Hard reload so Rails re-renders categories/topics/posts in the new
      // locale (Discourse's i18n strings are bundled per-request).
      window.location.reload();
    } catch (err) {
      // Network failure / 422 / 5xx all bubble through here. popupAjaxError
      // shows the standard Discourse modal and preserves the dropdown so the
      // user can retry without losing their place.
      popupAjaxError(err);
    } finally {
      this.saving = false;
    }
  }
}
