(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const viewMeta = {
    discover: ["VOTRE ESPACE", "Découvrir", "Découvrez les membres approuvés de BaddieLink."],
    likes: ["VOTRE SÉLECTION", "Mes likes", "Retrouvez les profils qui ont retenu votre attention."],
    messages: ["ÉCHANGER", "Messages", "Vos conversations privées."],
    wallet: ["VOTRE PORTEFEUILLE", "BaddieCoins", "Vos crédits et avantages BaddieLink."],
    profile: ["VOTRE IDENTITÉ", "Mon profil", "Gérez les informations visibles sur votre profil."],
    settings: ["VOS PRÉFÉRENCES", "Paramètres", "La configuration de votre espace BaddieLink."]
  };
  let toastTimer;

  function toast(message, isError = false) {
    const el = $("#toast");
    if (!el) return;
    el.textContent = message;
    el.classList.toggle("error", isError);
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 3000);
  }

  function showAuth(mode = "signup") {
    const signup = mode === "signup";
    window.__baddielinkMode = mode;
    $("#welcome")?.classList.add("hidden");
    $("#app-shell")?.classList.add("hidden");
    $("#auth-panel")?.classList.remove("hidden");
    $("#auth-title").textContent = signup ? "Créer votre compte" : "Se connecter";
    $("#auth-subtitle").textContent = signup
      ? "Quelques informations pour commencer."
      : "Ravi de vous retrouver sur BaddieLink.";
    $("#name-field").classList.toggle("hidden", !signup);
    $("#dob-field").classList.toggle("hidden", !signup);
    $("#date-of-birth").required = signup;
    $("#terms").required = signup;
    $("#terms").closest(".checkline")?.classList.toggle("hidden", !signup);
    $("#auth-submit").textContent = signup ? "Créer mon compte" : "Se connecter";
    $("#switch-auth").firstChild.textContent = signup
      ? "Vous avez déjà un compte ? "
      : "Pas encore de compte ? ";
    $("#switch-auth-button").textContent = signup ? "Se connecter" : "Créer un compte";
    $("#password").autocomplete = signup ? "new-password" : "current-password";
    const feedback = $("#auth-feedback");
    feedback?.classList.add("hidden");
    location.hash = signup ? "inscription" : "connexion";
  }

  function showWelcome() {
    $("#app-shell")?.classList.add("hidden");
    $("#auth-panel")?.classList.add("hidden");
    $("#welcome")?.classList.remove("hidden");
    $("#auth-signout")?.classList.add("hidden");
    location.hash = "";
  }

  function showView(view) {
    if (!viewMeta[view]) return;
    $$(".view").forEach(el => el.classList.toggle("active", el.id === "view-" + view));
    $$(".nav-item[data-view], .mobile-nav-item[data-view]").forEach(el => {
      const active = el.dataset.view === view;
      el.classList.toggle("active", active);
      if (el.classList.contains("mobile-nav-item")) {
        if (active) el.setAttribute("aria-current", "page");
        else el.removeAttribute("aria-current");
      }
    });
    const [kicker, title, description] = viewMeta[view];
    $("#view-kicker").textContent = kicker;
    $("#view-title").textContent = title;
    $("#view-description").textContent = description;
  }

  function showAgeGate() {
    let declared = false;
    try {
      declared = sessionStorage.getItem("baddielink-age-declared") === "1";
    } catch (error) {
      console.warn("Session storage is unavailable:", error);
    }
    if (!declared) $("#age-modal")?.classList.remove("hidden");
    else if (location.hash === "#inscription") showAuth("signup");
    else if (location.hash === "#connexion") showAuth("login");
  }

  function confirmAgeGate() {
    try {
      sessionStorage.setItem("baddielink-age-declared", "1");
    } catch (error) {
      console.warn("Could not persist the age declaration for this browser session:", error);
    }
    $("#age-modal")?.classList.add("hidden");
    if (location.hash === "#inscription") showAuth("signup");
    else if (location.hash === "#connexion") showAuth("login");
  }

  $("#header-login")?.addEventListener("click", () => showAuth("login"));
  $("#hero-login")?.addEventListener("click", () => showAuth("login"));
  $("#header-signup")?.addEventListener("click", () => showAuth("signup"));
  $("#hero-signup")?.addEventListener("click", () => showAuth("signup"));
  $("#back-home")?.addEventListener("click", showWelcome);
  $("#switch-auth-button")?.addEventListener("click", () => {
    showAuth(window.__baddielinkMode === "signup" ? "login" : "signup");
  });

  $$(".nav-item[data-view], .mobile-nav-item[data-view], .workspace-icon-button[data-view]").forEach(button => {
    button.addEventListener("click", () => showView(button.dataset.view));
  });
  $$("[data-goto]").forEach(button => {
    button.addEventListener("click", () => showView(button.dataset.goto));
  });
  $$("[data-discover-section]").forEach(button => {
    button.addEventListener("click", () => {
      const section = button.dataset.discoverSection;
      $$(".discover-tab").forEach(tab => {
        const active = tab === button;
        tab.classList.toggle("active", active);
        tab.setAttribute("aria-selected", String(active));
      });
      $$(".discover-panel").forEach(panel => {
        const active = panel.id === "discover-panel-" + section;
        panel.classList.toggle("active", active);
        panel.hidden = !active;
      });
    });
  });

  $("#logout")?.addEventListener("click", async () => {
    const client = window.baddielinkSupabase;
    if (!client) {
      toast("Le service de connexion est indisponible. Rechargez la page.", true);
      return;
    }
    const button = $("#logout");
    button.disabled = true;
    try {
      const { error } = await client.auth.signOut();
      if (error) throw error;
      showWelcome();
      toast("Vous êtes déconnecté.");
    } catch (error) {
      console.error("BaddieLink sign-out failed:", error);
      toast(error.message || "La déconnexion a échoué.", true);
    } finally {
      button.disabled = false;
    }
  });

  $("#age-confirm")?.addEventListener("click", confirmAgeGate);
  $("#age-decline")?.addEventListener("click", () => {
    $("#age-modal")?.classList.add("hidden");
    $("#welcome")?.classList.add("hidden");
    toast("L’accès à BaddieLink est réservé aux personnes majeures.");
  });

  function completeForm(form, message) {
    if (!form || !form.parentElement) return;
    const notice = document.createElement("div");
    notice.className = "form-completion";
    notice.setAttribute("role", "status");
    notice.setAttribute("aria-live", "polite");

    const copy = document.createElement("p");
    copy.textContent = message;
    const reopen = document.createElement("button");
    reopen.type = "button";
    reopen.className = "button button-outline";
    reopen.textContent = "Ouvrir à nouveau";
    reopen.addEventListener("click", () => {
      notice.remove();
      form.classList.remove("hidden");
      form.querySelector("input:not([type=hidden]):not(:disabled), textarea:not(:disabled), select:not(:disabled)")?.focus();
    });

    notice.append(copy, reopen);
    form.classList.add("hidden");
    form.insertAdjacentElement("afterend", notice);
  }

  window.BaddieLinkUI = Object.freeze({ showAuth, showWelcome, showView, toast, completeForm });
  showAgeGate();
})();