import { withPluginApi } from "discourse/lib/plugin-api";

const COOKIE = "mp_onboarding_seen";

function alreadyOnboarded(user) {
  if (!user) return true;
  const fields = user.custom_fields || {};
  return fields.mp_onboarded === "1" || fields.mp_onboarded === true;
}

export default {
  name: "multilingual-post-onboarding-trigger",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.multilingual_post_force_language_selection_on_first_login) {
      return;
    }
    const currentUser = container.lookup("service:current-user");
    if (!currentUser) return;
    if (alreadyOnboarded(currentUser)) return;

    withPluginApi("1.13.0", (api) => {
      api.onPageChange(() => {
        if (alreadyOnboarded(currentUser)) return;
        const modal = container.lookup("service:modal");
        if (!modal) return;
        modal.show("multilingual-post/onboarding-modal", {
          model: { user: currentUser },
        });
      });
    });
  },
};
