import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { service } from "@ember/service";

const STORAGE_KEY = "mp_empty_profile_dismissed_until";

export default class EmptyProfileBanner extends Component {
  @service currentUser;
  @service siteSettings;

  @tracked dismissed = this.isDismissed();

  get shouldShow() {
    if (!this.currentUser) return false;
    if (this.dismissed) return false;
    if (!this.bioIsEmpty) return false;
    return true;
  }

  get bioIsEmpty() {
    const bio = this.currentUser.bio_raw || this.currentUser.user_option?.bio_raw;
    return !bio || bio.trim() === "";
  }

  isDismissed() {
    try {
      const until = parseInt(
        window.localStorage.getItem(STORAGE_KEY) || "0",
        10
      );
      return Date.now() < until;
    } catch (e) {
      return false;
    }
  }

  @action edit() {
    if (!this.currentUser) return;
    window.location.href = `/u/${this.currentUser.username}/preferences/profile`;
  }

  @action dismiss() {
    this.snooze(this.siteSettings.multilingual_post_empty_profile_banner_dismiss_days || 7);
  }

  @action later() {
    this.snooze(3);
  }

  snooze(days) {
    try {
      const until = Date.now() + days * 24 * 60 * 60 * 1000;
      window.localStorage.setItem(STORAGE_KEY, String(until));
    } catch (e) {}
    this.dismissed = true;
  }
}
