import { withPluginApi } from "discourse/lib/plugin-api";
import OnboardingModal from "../components/onboarding-modal";

/**
 * First-login onboarding trigger.
 *
 * Opens the onboarding modal exactly once per session for users who haven't
 * gone through the flow yet (no `mp_onboarded` custom field). The previous
 * implementation re-fired the modal on every onPageChange — modal.show is
 * idempotent enough that you wouldn't see duplicates, but it created a busy
 * call in the page-change hot path. We now use a session-scoped flag so the
 * trigger logic short-circuits after the first invocation.
 */

const SESSION_FLAG = "mp_onboarding_triggered";

function alreadyOnboarded(user) {
  if (!user) {
    return true;
  }
  const fields = user.custom_fields || {};
  return fields.mp_onboarded === "1" || fields.mp_onboarded === true;
}

export default {
  name: "multilingual-post-onboarding-trigger",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (
      !siteSettings?.multilingual_post_force_language_selection_on_first_login
    ) {
      return;
    }

    const currentUser = container.lookup("service:current-user");
    if (!currentUser) {
      return;
    }
    if (alreadyOnboarded(currentUser)) {
      return;
    }

    // Already triggered this tab/session — don't reopen if the user closed it.
    // This is intentionally per-tab (sessionStorage) so refreshing the tab
    // brings it back up if the user reloaded mid-flow.
    try {
      if (window.sessionStorage?.getItem(SESSION_FLAG) === "1") {
        return;
      }
    } catch {
      // sessionStorage may throw in private mode; treat as "not triggered".
    }

    withPluginApi("1.13.0", (api) => {
      // Use onPageChange so we wait for the router to settle on the first
      // post-login page (otherwise modal.show during boot can race with the
      // application route's own modal stack).
      const off = api.onPageChange?.(() => {
        if (alreadyOnboarded(currentUser)) {
          off?.();
          return;
        }
        try {
          window.sessionStorage?.setItem(SESSION_FLAG, "1");
        } catch {
          // ignore — flag is best-effort
        }

        const modal = container.lookup("service:modal");
        if (!modal) {
          return;
        }
        // Modern Discourse modal API: pass a component class, not a route
        // string. The component receives `closeModal` automatically.
        modal.show(OnboardingModal, {
          model: { user: currentUser },
        });

        // Detach this hook — we only ever fire once.
        off?.();
      });
    });
  },
};
