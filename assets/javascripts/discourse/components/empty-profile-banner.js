import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";

const STORAGE_KEY = "mp_empty_profile_dismissed_until";
const MS_PER_DAY = 24 * 60 * 60 * 1000;
const DEFAULT_DISMISS_DAYS = 7;
const LATER_DAYS = 3;

/**
 * Soft "your profile is empty" banner.
 *
 * Why this component exists:
 *  - PLAN.md §「やわらかいナッジ」requires a *closeable* nudge with a graceful
 *    snooze (close = 7d, later = 3d) — implemented in `localStorage` so we
 *    don't round-trip the server on every page view.
 *
 * Notes:
 *  - We avoid `currentUser.set(...)` (legacy Ember mutation) and never write
 *    back to the user model from this banner — only local snooze state.
 *  - Navigation goes through `router.transitionTo` to keep SPA state intact
 *    instead of `window.location.href` which throws away the Ember runtime.
 */
export default class EmptyProfileBanner extends Component {
  @service currentUser;
  @service siteSettings;
  @service router;

  @tracked dismissed = this.#readDismissed();

  get shouldShow() {
    if (!this.currentUser) {
      return false;
    }
    if (this.dismissed) {
      return false;
    }
    return this.bioIsEmpty;
  }

  get bioIsEmpty() {
    // `bio_raw` is exposed on the user-card / current-user serializers; fall
    // back to user_option for older payload shapes.
    const bio =
      this.currentUser.bio_raw ?? this.currentUser.user_option?.bio_raw ?? "";
    return bio.trim() === "";
  }

  #readDismissed() {
    try {
      const raw = window.localStorage?.getItem(STORAGE_KEY);
      if (!raw) {
        return false;
      }
      const until = parseInt(raw, 10);
      return Number.isFinite(until) && Date.now() < until;
    } catch {
      // localStorage may throw in private mode / disabled storage.
      return false;
    }
  }

  #snooze(days) {
    try {
      const until = Date.now() + days * MS_PER_DAY;
      window.localStorage?.setItem(STORAGE_KEY, String(until));
    } catch {
      // Best-effort only: even if persistence fails, hide for this session.
    }
    this.dismissed = true;
  }

  @action
  edit() {
    if (!this.currentUser) {
      return;
    }
    // Use the router so we keep the SPA shell instead of a full page reload.
    this.router.transitionTo(
      "preferences.profile",
      this.currentUser.username
    );
  }

  @action
  dismiss() {
    const days =
      this.siteSettings?.multilingual_post_empty_profile_banner_dismiss_days ||
      DEFAULT_DISMISS_DAYS;
    this.#snooze(days);
  }

  @action
  later() {
    this.#snooze(LATER_DAYS);
  }

  /**
   * Allow the user to dismiss with the Escape key when focus is anywhere
   * inside the banner — accessibility nicety for keyboard users.
   */
  @action
  onKeydown(event) {
    if (event.key === "Escape") {
      event.stopPropagation();
      this.later();
    }
  }
}
