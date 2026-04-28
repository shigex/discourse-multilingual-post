import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { service } from "@ember/service";

const LOCALES = [
  { code: "ja", label: "日本語" },
  { code: "en", label: "English" },
  { code: "ko", label: "한국어" },
  { code: "de", label: "Deutsch" },
  { code: "es", label: "Español" },
  { code: "zh-CN", label: "中文 (简体)" },
  { code: "zh-TW", label: "中文 (繁體)" },
  { code: "fr", label: "Français" },
  // Tier 2 — selectable, on-demand translation
  { code: "pt", label: "Português" },
  { code: "it", label: "Italiano" },
  { code: "ru", label: "Русский" },
  { code: "bn", label: "বাংলা" },
  { code: "vi", label: "Tiếng Việt" },
  { code: "id", label: "Bahasa Indonesia" },
  { code: "pl", label: "Polski" },
];

export default class LanguagePicker extends Component {
  @service currentUser;
  @service router;
  @tracked open = false;

  get currentLabel() {
    const locale = this.currentUser?.locale;
    return LOCALES.find((l) => l.code === locale)?.label ?? locale ?? "🌐";
  }

  get locales() {
    return LOCALES;
  }

  @action toggle() {
    this.open = !this.open;
  }

  @action async select(code) {
    this.open = false;
    if (!this.currentUser) return;
    try {
      await ajax(`/u/${this.currentUser.username}.json`, {
        type: "PUT",
        data: { locale: code },
      });
      this.currentUser.set("locale", code);
      // Hard-reload so server-rendered translations rehydrate in the new locale.
      window.location.reload();
    } catch (err) {
      popupAjaxError(err);
    }
  }
}
