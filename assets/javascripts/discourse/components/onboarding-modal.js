import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

/**
 * Tier 1 (pre-cached at post-time, see PLAN.md). Order matches plugin.rb.
 */
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

/**
 * Tier 2 (selectable but lazy-translated). Native-script only, no flags.
 */
const TIER2 = [
  { code: "pt", label: "Português" },
  { code: "it", label: "Italiano" },
  { code: "ru", label: "Русский" },
  { code: "bn", label: "বাংলা" },
  { code: "vi", label: "Tiếng Việt" },
  { code: "id", label: "Bahasa Indonesia" },
  { code: "pl", label: "Polski" },
];

/**
 * Open-to options. Keys must match the locale entries under
 * `multilingual_post.onboarding_profile.open_to.*` in client.{en,ja}.yml.
 */
const OPEN_TO_OPTIONS = [
  "coffee_chat",
  "dinner_buddy",
  "language_exchange",
  "stroll",
  "study",
];

/**
 * Multi-step first-login onboarding modal.
 *
 *  Step 1: language selection (forced, all users; PLAN.md §「言語選択 UX」)
 *  Step 2: username confirmation (Google only — LINE keeps displayName as-is)
 *  Step 3: profile bootstrap (skippable, soft nudge)
 *
 * The component is rendered inside a `<DModal>` from the .hbs file, so
 * dismissal / Esc / focus-trap are handled by Discourse's modal infrastructure.
 * This class only owns step state and the persistence calls.
 *
 * Props expected via `@args`:
 *   - `closeModal`: function — provided automatically by `service:modal`.
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
  @tracked saving = false;
  @tracked errorMessage = null;

  constructor() {
    super(...arguments);
    // Compute the suggested locale once and reuse — `navigator.languages`
    // shouldn't change mid-session, and recomputing on every getter access
    // is wasteful.
    this._suggestedLocale = this.#computeSuggestedLocale();
    this.selectedLocale = this._suggestedLocale;
    this.username = this.currentUser?.username ?? "";
    // Pre-tick the user's suggested locale in "languages I speak" — they can
    // uncheck it if they're learning rather than fluent.
    this.spokenLanguages = this._suggestedLocale ? [this._suggestedLocale] : [];
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

  get suggestedLocale() {
    return this._suggestedLocale;
  }

  /**
   * Title shown in the <DModal> header. Switches per step so screen-readers
   * announce step transitions (the modal title is read on focus return).
   */
  get modalTitle() {
    if (this.step === 2) {
      return i18n("multilingual_post.onboarding_username.title");
    }
    if (this.step === 3) {
      return i18n("multilingual_post.onboarding_profile.title");
    }
    return i18n("multilingual_post.onboarding.title");
  }

  /**
   * Step 1 (language selection) is intentionally non-dismissable: the plan
   * requires users to pick a locale before they can use the site. Steps 2/3
   * are skippable, so we let Esc / click-outside close them.
   */
  get dismissable() {
    return this.step !== 1;
  }

  get isGoogleUser() {
    // Discourse exposes attached identities under `associated_accounts`.
    // We treat absence as non-Google so step 2 is skipped — LINE keeps
    // displayName, and a missing array shouldn't strand the user on step 2.
    return (this.currentUser?.associated_accounts || []).some(
      (a) => a.name === "google_oauth2"
    );
  }

  /**
   * Pick a Tier-1 locale from `navigator.languages`.
   * Falls back to "en" so the user is never stuck on a blank suggestion.
   */
  #computeSuggestedLocale() {
    const candidates = navigator.languages ||
      (navigator.language ? [navigator.language] : []);
    for (const raw of candidates) {
      const lower = (raw || "").toLowerCase();
      if (!lower) {
        continue;
      }
      // Exact match first (handles zh-CN / zh-TW correctly).
      const exact = TIER1.find((l) => l.code.toLowerCase() === lower);
      if (exact) {
        return exact.code;
      }
      // Then prefix (e.g. "en-US" → "en", "de-AT" → "de").
      const prefix = TIER1.find((l) =>
        lower.startsWith(`${l.code.toLowerCase()}-`)
      );
      if (prefix) {
        return prefix.code;
      }
    }
    return "en";
  }

  @action
  selectLocale(code) {
    this.selectedLocale = code;
  }

  @action
  toggleTier2() {
    this.showTier2 = !this.showTier2;
  }

  @action
  toggleSpoken(code) {
    if (this.spokenLanguages.includes(code)) {
      this.spokenLanguages = this.spokenLanguages.filter((c) => c !== code);
    } else {
      this.spokenLanguages = [...this.spokenLanguages, code];
    }
  }

  @action
  toggleOpenTo(value) {
    if (this.openTo.includes(value)) {
      this.openTo = this.openTo.filter((c) => c !== value);
    } else {
      this.openTo = [...this.openTo, value];
    }
  }

  @action
  async saveLocale() {
    if (!this.selectedLocale || this.saving) {
      return;
    }
    const ok = await this.#persist({ locale: this.selectedLocale });
    if (!ok) {
      return; // stay on step 1 so the user can retry
    }
    // Mutate locally so the rest of the modal flow uses the new locale, but
    // don't reload yet — we still have steps 2/3 to complete.
    if (this.currentUser) {
      this.currentUser.locale = this.selectedLocale;
    }
    this.step = this.isGoogleUser ? 2 : 3;
  }

  @action
  async saveUsername() {
    if (this.saving) {
      return;
    }
    const trimmed = (this.username || "").trim();
    if (!trimmed || trimmed === this.currentUser?.username) {
      // Nothing to do — proceed to step 3.
      this.step = 3;
      return;
    }
    this.saving = true;
    this.errorMessage = null;
    try {
      await ajax(`/u/${this.currentUser.username}/preferences/username`, {
        type: "PUT",
        data: { new_username: trimmed },
      });
      this.currentUser.username = trimmed;
      this.step = 3;
    } catch (err) {
      // Use Discourse's standard error popup, but also surface the message
      // inline so the user understands why they're still on this step.
      popupAjaxError(err);
      this.errorMessage =
        err?.jqXHR?.responseJSON?.errors?.[0] ||
        err?.message ||
        null;
    } finally {
      this.saving = false;
    }
  }

  @action
  async saveProfile() {
    if (this.saving) {
      return;
    }
    const ok = await this.#persist({
      bio_raw: this.bio,
      // Discourse stores user custom fields under `custom_fields` on the
      // user-update endpoint — array values must be serialised as
      // comma-separated strings (Discourse's coerce_to_string helper).
      custom_fields: {
        spoken_languages: this.spokenLanguages.join(","),
        open_to: this.openTo.join(","),
      },
    });
    if (ok) {
      await this.#finish();
    }
  }

  @action
  async skipProfile() {
    await this.#finish();
  }

  /**
   * Wraps the user-update PUT with shared error handling so each step gets
   * uniform retry behaviour. Returns true on success, false on failure (so
   * callers know whether to advance the step).
   */
  async #persist(data) {
    if (!this.currentUser) {
      return false;
    }
    this.saving = true;
    this.errorMessage = null;
    try {
      await ajax(`/u/${this.currentUser.username}.json`, {
        type: "PUT",
        data,
      });
      return true;
    } catch (err) {
      popupAjaxError(err);
      this.errorMessage =
        err?.jqXHR?.responseJSON?.errors?.[0] ||
        err?.message ||
        null;
      return false;
    } finally {
      this.saving = false;
    }
  }

  /**
   * Mark the user onboarded (so the trigger initializer doesn't re-open us)
   * and close the modal. We await the PUT — if the network drops between
   * close-modal and the flag landing on the server, the user just sees the
   * modal again on next page load, which is the correct soft-failure mode.
   */
  async #finish() {
    if (this.currentUser) {
      this.saving = true;
      try {
        await ajax(`/u/${this.currentUser.username}.json`, {
          type: "PUT",
          data: { custom_fields: { mp_onboarded: "1" } },
        });
        if (!this.currentUser.custom_fields) {
          this.currentUser.custom_fields = {};
        }
        this.currentUser.custom_fields.mp_onboarded = "1";
      } catch (err) {
        // Don't block the user — just log; they'll see the modal again next
        // page load, which is recoverable. We deliberately swallow errors
        // here instead of popupAjaxError so close still happens.
        // eslint-disable-next-line no-console
        console.warn("[multilingual-post] could not persist mp_onboarded", err);
      } finally {
        this.saving = false;
      }
    }
    this.args.closeModal?.();
  }
}
