import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { service } from "@ember/service";

const TIER1 = [
  { code: "ja", label: "日本語" },
  { code: "en", label: "English" },
  { code: "ko", label: "한국어" },
  { code: "de", label: "Deutsch" },
  { code: "es", label: "Español" },
  { code: "zh-CN", label: "中文 (简体)" },
  { code: "zh-TW", label: "中文 (繁體)" },
  { code: "fr", label: "Français" },
];

const TIER2 = [
  { code: "pt", label: "Português" },
  { code: "it", label: "Italiano" },
  { code: "ru", label: "Русский" },
  { code: "bn", label: "বাংলা" },
  { code: "vi", label: "Tiếng Việt" },
  { code: "id", label: "Bahasa Indonesia" },
  { code: "pl", label: "Polski" },
];

const OPEN_TO_OPTIONS = [
  "coffee_chat",
  "dinner_buddy",
  "language_exchange",
  "stroll",
  "study",
];

/**
 * Multi-step onboarding modal:
 *  Step 1: language selection (forced, all users)
 *  Step 2: username confirmation (Google only — LINE keeps displayName as-is)
 *  Step 3: profile bootstrap (skippable)
 */
export default class OnboardingModal extends Component {
  @service currentUser;
  @service router;

  @tracked step = 1;
  @tracked selectedLocale = null;
  @tracked username = "";
  @tracked bio = "";
  @tracked spokenLanguages = [];
  @tracked openTo = [];
  @tracked showTier2 = false;

  constructor() {
    super(...arguments);
    this.selectedLocale = this.suggestedLocale;
    this.username = this.currentUser?.username ?? "";
    this.spokenLanguages = this.suggestedLocale ? [this.suggestedLocale] : [];
  }

  get tier1() {
    return TIER1;
  }

  get tier2() {
    return TIER2;
  }

  get openToOptions() {
    return OPEN_TO_OPTIONS;
  }

  get isGoogleUser() {
    // The auth provider name is exposed on currentUser.associated_accounts.
    return (this.currentUser?.associated_accounts || []).some(
      (a) => a.name === "google_oauth2"
    );
  }

  get suggestedLocale() {
    const accept = (navigator.languages || [navigator.language || ""])[0] || "";
    const lower = accept.toLowerCase();
    // Try exact then prefix match against Tier 1.
    const exact = TIER1.find(
      (l) => l.code.toLowerCase() === lower
    );
    if (exact) return exact.code;
    const prefix = TIER1.find((l) => lower.startsWith(l.code.toLowerCase()));
    if (prefix) return prefix.code;
    return "en";
  }

  @action selectLocale(code) {
    this.selectedLocale = code;
  }

  @action toggleTier2() {
    this.showTier2 = !this.showTier2;
  }

  @action toggleSpoken(code) {
    if (this.spokenLanguages.includes(code)) {
      this.spokenLanguages = this.spokenLanguages.filter((c) => c !== code);
    } else {
      this.spokenLanguages = [...this.spokenLanguages, code];
    }
  }

  @action toggleOpenTo(value) {
    if (this.openTo.includes(value)) {
      this.openTo = this.openTo.filter((c) => c !== value);
    } else {
      this.openTo = [...this.openTo, value];
    }
  }

  @action async saveLocale() {
    if (!this.selectedLocale) return;
    await this.persist({ locale: this.selectedLocale });
    this.step = this.isGoogleUser ? 2 : 3;
  }

  @action async saveUsername() {
    if (!this.username) {
      this.step = 3;
      return;
    }
    try {
      await ajax(`/u/${this.currentUser.username}/preferences/username`, {
        type: "PUT",
        data: { new_username: this.username },
      });
      this.currentUser.set("username", this.username);
    } catch (err) {
      popupAjaxError(err);
      return;
    }
    this.step = 3;
  }

  @action async saveProfile() {
    await this.persist({
      bio_raw: this.bio,
      custom_fields: {
        spoken_languages: this.spokenLanguages.join(","),
        open_to: this.openTo.join(","),
      },
    });
    this.finish();
  }

  @action skipProfile() {
    this.finish();
  }

  finish() {
    if (this.args.close) this.args.close();
    // Mark as onboarded so the modal doesn't reappear.
    if (this.currentUser) {
      this.currentUser.set("custom_fields.mp_onboarded", "1");
      ajax(`/u/${this.currentUser.username}.json`, {
        type: "PUT",
        data: { custom_fields: { mp_onboarded: "1" } },
      });
    }
  }

  async persist(data) {
    if (!this.currentUser) return;
    try {
      await ajax(`/u/${this.currentUser.username}.json`, {
        type: "PUT",
        data,
      });
    } catch (err) {
      popupAjaxError(err);
    }
  }
}
