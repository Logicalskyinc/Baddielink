(() => {
  "use strict";

  const config = window.BADDIELINK_SUPABASE;
  const supabaseFactory = window.supabase && window.supabase.createClient;
  if (!config || !supabaseFactory) {
    console.error("BaddieLink authentication could not initialize.");
    return;
  }

  const client = supabaseFactory(config.url, config.publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      flowType: "pkce"
    }
  });
  window.baddielinkSupabase = client;

  const $ = (selector) => document.querySelector(selector);
  const feedback = $("#auth-feedback");
  const submit = $("#auth-submit");
  const form = $("#auth-form");
  const dobField = $("#dob-field");
  const dobInput = $("#date-of-birth");
  const nameInput = $("#full-name");
  const emailInput = $("#email");
  const passwordInput = $("#password");
  const terms = $("#terms");
  let busy = false;

  function message(text, isError = false) {
    if (!feedback) return;
    feedback.textContent = text;
    feedback.classList.remove("hidden");
    feedback.style.color = isError ? "#ff9aa8" : "#a7e0bd";
  }

  function setBusy(value) {
    busy = value;
    if (submit) {
      submit.disabled = value;
      submit.textContent = value ? "Veuillez patienter…" : (window.__baddielinkMode === "login" ? "Se connecter" : "Créer mon compte");
    }
  }

  function calculateAge(dateString) {
    if (!dateString) return -1;
    const dob = new Date(dateString + "T00:00:00");
    if (Number.isNaN(dob.getTime())) return -1;
    const today = new Date();
    let age = today.getFullYear() - dob.getFullYear();
    const month = today.getMonth() - dob.getMonth();
    if (month < 0 || (month === 0 && today.getDate() < dob.getDate())) age--;
    return age;
  }

  async function ensureAdultDeclaration(user) {
    const { data: settings, error } = await client
      .from("user_private_settings")
      .select("date_of_birth, age_declaration_at")
      .eq("user_id", user.id)
      .maybeSingle();

    if (error) throw error;
    if (settings && settings.date_of_birth && settings.age_declaration_at) return true;

    dobField.classList.remove("hidden");
    dobInput.required = true;
    message("Avant d’accéder à BaddieLink, indiquez votre date de naissance. L’accès est réservé aux personnes âgées de 18 ans ou plus.");

    const date = dobInput.value;
    if (!date) return false;
    const age = calculateAge(date);
    if (age < 18 || age > 100) {
      message("Vous devez avoir entre 18 et 100 ans pour créer un compte.", true);
      return false;
    }

    const { error: declarationError } = await client.rpc("confirm_adult_status", {
      p_date_of_birth: date
    });
    if (declarationError) throw declarationError;
    return true;
  }

  async function enterAuthenticatedApp(user) {
    const { data: profile, error } = await client
      .from("profiles")
      .select("display_name, username, moderation_status, is_discoverable")
      .eq("id", user.id)
      .single();
    if (error) throw error;

    $("#auth-panel").classList.add("hidden");
    $("#welcome").classList.add("hidden");
    $("#app-shell").classList.remove("hidden");
    const displayName = profile.display_name || user.email || "Membre BaddieLink";
    $("#sidebar-name").textContent = displayName;
    $("#profile-name").textContent = displayName;
    document.querySelectorAll(".avatar-user").forEach(el => {
      el.textContent = displayName.trim().charAt(0).toUpperCase() || "B";
    });

    // Until live discovery and messaging APIs are implemented, do not show
    // fictional demo accounts or sample conversations to authenticated users.
    $("#profile-grid").innerHTML = "";
    $("#likes-grid").innerHTML = "";
    $("#view-discover .filter-row").classList.add("hidden");
    $("#view-discover").innerHTML = '<div class="empty-state"><span>✦</span><h3>Votre compte est connecté</h3><p>Votre profil est enregistré. La découverte de membres réels sera activée après la prochaine étape de développement.</p></div>';
    $("#view-messages").innerHTML = '<div class="empty-state"><span>✉</span><h3>Messagerie en préparation</h3><p>La messagerie réelle sera activée après les tests de sécurité.</p></div>';
    $("#view-likes").innerHTML = '<div class="empty-state"><span>♡</span><h3>Vos coups de cœur</h3><p>Les likes réels seront activés avec la découverte des profils.</p></div>';
    $("#auth-signout").classList.remove("hidden");
    document.querySelectorAll(".demo-note").forEach(el => {
      if (el.closest("#auth-panel")) el.classList.add("hidden");
    });
    if (profile.moderation_status !== "approved") {
      message("Votre profil est en attente de modération. Il ne sera pas visible par les autres membres avant approbation.");
    }
    location.hash = "espace";
  }

  async function submitAuth(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (busy) return;
    setBusy(true);
    try {
      const email = emailInput.value.trim().toLowerCase();
      const password = passwordInput.value;
      const mode = document.querySelector("#auth-title").textContent.includes("connecter") ? "login" : "signup";

      if (!email || password.length < 8) throw new Error("Vérifiez votre adresse e-mail et votre mot de passe (8 caractères minimum).");

      if (mode === "signup") {
        const displayName = nameInput.value.trim();
        const dob = dobInput.value;
        if (!displayName) throw new Error("Veuillez saisir un nom affiché.");
        if (!terms.checked) throw new Error("Vous devez accepter les conditions d’utilisation.");
        const age = calculateAge(dob);
        if (age < 18 || age > 100) throw new Error("BaddieLink est réservé aux personnes âgées de 18 à 100 ans.");

        const { data, error } = await client.auth.signUp({
          email,
          password,
          options: {
            data: { display_name: displayName },
            emailRedirectTo: window.location.origin + window.location.pathname
          }
        });
        if (error) throw error;

        if (!data.session) {
          message("Compte créé. Consultez votre boîte e-mail pour confirmer votre adresse, puis connectez-vous et confirmez votre date de naissance.");
          return;
        }

        const { error: ageError } = await client.rpc("confirm_adult_status", { p_date_of_birth: dob });
        if (ageError) throw ageError;
        await enterAuthenticatedApp(data.user);
        return;
      }

      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
      const adult = await ensureAdultDeclaration(data.user);
      if (!adult) return;
      await enterAuthenticatedApp(data.user);
    } catch (error) {
      console.error("BaddieLink auth error:", error);
      message(error.message || "Une erreur est survenue. Réessayez.", true);
    } finally {
      setBusy(false);
    }
  }

  form.addEventListener("submit", submitAuth, true);

  $("#auth-signout").addEventListener("click", async () => {
    setBusy(true);
    try {
      const { error } = await client.auth.signOut();
      if (error) throw error;
      $("#app-shell").classList.add("hidden");
      $("#welcome").classList.remove("hidden");
      $("#auth-signout").classList.add("hidden");
      location.hash = "";
      message("Vous êtes déconnecté.");
    } catch (error) {
      message(error.message || "La déconnexion a échoué.", true);
    } finally {
      setBusy(false);
    }
  });

  client.auth.onAuthStateChange((event, session) => {
    if (event === "SIGNED_OUT") {
      $("#auth-signout").classList.add("hidden");
    }
  });

  (async () => {
    const { data, error } = await client.auth.getSession();
    if (error) {
      console.error("Unable to restore BaddieLink session:", error);
      return;
    }
    if (!data.session) return;
    try {
      const adult = await ensureAdultDeclaration(data.session.user);
      if (adult) await enterAuthenticatedApp(data.session.user);
    } catch (restoreError) {
      console.error("BaddieLink session restore failed:", restoreError);
      message("Votre session est active, mais votre profil doit être vérifié avant de continuer.", true);
    }
  })();
})();
