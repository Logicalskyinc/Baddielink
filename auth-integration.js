(() => {
  "use strict";

  const config = window.BADDIELINK_SUPABASE;
  const supabaseFactory = window.supabase && window.supabase.createClient;
  const feedback = document.querySelector("#auth-feedback");
  const submit = document.querySelector("#auth-submit");
  const form = document.querySelector("#auth-form");
  const dobField = document.querySelector("#dob-field");
  const dobInput = document.querySelector("#date-of-birth");
  const nameInput = document.querySelector("#full-name");
  const emailInput = document.querySelector("#email");
  const passwordInput = document.querySelector("#password");
  const terms = document.querySelector("#terms");
  let busy = false;
  let currentUserId = null;

  function message(text, isError = false) {
    if (!feedback) return;
    feedback.textContent = text;
    feedback.classList.remove("hidden");
    feedback.style.color = isError ? "#ff9aa8" : "#a7e0bd";
  }

  function setBusy(value) {
    busy = value;
    if (!submit) return;
    submit.disabled = value;
    submit.textContent = value
      ? "Veuillez patienter…"
      : (window.__baddielinkMode === "login" ? "Se connecter" : "Créer mon compte");
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

  function showAuth(mode) {
    window.BaddieLinkUI?.showAuth(mode);
  }

  async function ensureAdultDeclaration(user) {
    const { data: settings, error } = await client
      .from("user_private_settings")
      .select("date_of_birth, age_declaration_at")
      .eq("user_id", user.id)
      .maybeSingle();

    if (error) throw error;
    if (settings?.date_of_birth && settings?.age_declaration_at) return true;

    showAuth("login");
    dobField.classList.remove("hidden");
    dobInput.required = true;
    message("Avant d’accéder à BaddieLink, indiquez votre date de naissance. L’accès est réservé aux personnes âgées de 18 ans ou plus. Cette déclaration n’est pas une vérification officielle.");

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
    currentUserId = user.id;
    const { data: profile, error } = await client
      .from("profiles")
      .select("display_name, username, bio, city, interested_in, moderation_status, is_discoverable")
      .eq("id", user.id)
      .single();
    if (error) throw error;

    document.querySelector("#auth-panel").classList.add("hidden");
    document.querySelector("#welcome").classList.add("hidden");
    document.querySelector("#app-shell").classList.remove("hidden");

    const displayName = profile.display_name || user.email || "Membre BaddieLink";
    document.querySelector("#sidebar-name").textContent = displayName;
    document.querySelector("#profile-name").textContent = displayName;
    document.querySelectorAll(".avatar-user").forEach(el => {
      el.textContent = displayName.trim().charAt(0).toUpperCase() || "B";
    });

    const sidebarStatus = document.querySelector(".sidebar-user span");
    if (sidebarStatus) sidebarStatus.textContent = "Compte connecté";
    const profileSubtitle = document.querySelector("#profile-subtitle");
    if (profileSubtitle) profileSubtitle.textContent = "@" + profile.username + " · " + profile.city + " · Côte d’Ivoire";
    const profileBio = document.querySelector("#profile-bio");
    if (profileBio) profileBio.textContent = profile.bio || "Ajoutez une courte présentation.";
    const interestLabels = { friendship: "Amitié", dating: "Rencontres", networking: "Réseautage", discussion: "Discussions", events: "Événements" };
    const interestText = (profile.interested_in || []).map(value => interestLabels[value] || value).join(" · ");
    const profileInterests = document.querySelector("#profile-interests");
    if (profileInterests) profileInterests.textContent = interestText || "Aucun centre d’intérêt ajouté.";
    const visibility = document.querySelector("#profile-visibility");
    if (visibility) visibility.textContent = profile.is_discoverable ? "Découvrable (après approbation)" : "Non visible dans la découverte";
    const editButton = document.querySelector("#edit-profile");
    if (editButton) editButton.onclick = () => openProfileEditor(profile);

    // Never expose prototype profiles, fake likes, or sample conversations to real members.
    document.querySelector("#profile-grid").innerHTML = "";
    document.querySelector("#likes-grid").innerHTML = "";
    document.querySelector("#view-discover .filter-row")?.classList.add("hidden");
    const discoverStatus = document.querySelector("#discover-member-status");
    if (discoverStatus) {
      discoverStatus.textContent = "Votre compte est connecté. La découverte des membres sera activée après validation des règles de visibilité et de sécurité.";
    }
    document.querySelector("#view-messages").innerHTML =
      '<div class="empty-state"><span>✉</span><h3>Messagerie en préparation</h3><p>La messagerie réelle sera activée après les tests d’accès et de confidentialité.</p></div>';
    document.querySelector("#view-likes").innerHTML =
      '<div class="empty-state"><span>♡</span><h3>Vos coups de cœur</h3><p>Les likes réels seront activés avec la découverte des profils.</p></div>';
    document.querySelector("#view-wallet").innerHTML =
      '<div class="empty-state"><span>◇</span><h3>BaddieCoins en préparation</h3><p>Aucun solde fictif ni achat n’est affiché. Le portefeuille sera activé après la mise en place du registre sécurisé.</p></div>';
    document.querySelector("#auth-signout").classList.add("hidden");

    if (profile.moderation_status !== "approved") {
      window.BaddieLinkUI?.toast("Votre profil est en attente de modération. Il ne sera pas visible par les autres membres avant approbation.");
    }
    location.hash = "espace";
  }

  function openProfileEditor(profile) {
    const modal = document.querySelector("#profile-editor-modal");
    const form = document.querySelector("#profile-editor-form");
    if (!modal || !form) return;
    form.elements.display_name.value = profile.display_name || "";
    form.elements.username.value = profile.username || "";
    form.elements.city.value = profile.city || "Abidjan";
    form.elements.bio.value = profile.bio || "";
    form.elements.is_discoverable.checked = Boolean(profile.is_discoverable);
    const selected = new Set(profile.interested_in || []);
    form.querySelectorAll('input[name="interested_in"]').forEach(input => {
      input.checked = selected.has(input.value);
    });
    document.querySelector("#profile-editor-feedback").classList.add("hidden");
    modal.classList.remove("hidden");
  }

  function closeProfileEditor() {
    document.querySelector("#profile-editor-modal")?.classList.add("hidden");
  }

  document.querySelector("#close-profile-editor")?.addEventListener("click", closeProfileEditor);
  document.querySelector("#cancel-profile-editor")?.addEventListener("click", closeProfileEditor);
  document.querySelector("#profile-editor-modal")?.addEventListener("click", event => {
    if (event.target.id === "profile-editor-modal") closeProfileEditor();
  });

  document.querySelector("#profile-editor-form")?.addEventListener("submit", async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const feedback = document.querySelector("#profile-editor-feedback");
    const save = document.querySelector("#save-profile");
    const displayName = form.elements.display_name.value.trim();
    const username = form.elements.username.value.trim().toLowerCase();
    const city = form.elements.city.value.trim();
    const bio = form.elements.bio.value.trim();
    const interests = [...form.querySelectorAll('input[name="interested_in"]:checked')].map(input => input.value);
    const isDiscoverable = form.elements.is_discoverable.checked;

    feedback.classList.add("hidden");
    const showFeedback = (text, isError = false) => {
      feedback.textContent = text;
      feedback.style.color = isError ? "#ff9aa8" : "#a7e0bd";
      feedback.classList.remove("hidden");
    };

    if (displayName.length < 1 || displayName.length > 60) return showFeedback("Le nom affiché doit contenir entre 1 et 60 caractères.", true);
    if (!/^[a-z0-9_]{3,24}$/.test(username)) return showFeedback("Le nom d’utilisateur doit contenir 3 à 24 caractères : lettres minuscules, chiffres ou _.", true);
    if (!city || city.length > 80) return showFeedback("Indiquez une ville valide (80 caractères maximum).", true);
    if (bio.length > 500) return showFeedback("Votre présentation ne peut pas dépasser 500 caractères.", true);

    save.disabled = true;
    save.textContent = "Enregistrement…";
    try {
      const { data, error } = await client
        .from("profiles")
        .update({
          display_name: displayName,
          username,
          city,
          bio,
          interested_in: interests,
          is_discoverable: isDiscoverable
        })
        .eq("id", currentUserId)
        .select("display_name, username, city, bio, interested_in, is_discoverable, moderation_status")
        .single();
      if (error) throw error;

      document.querySelector("#profile-name").textContent = data.display_name;
      document.querySelector("#sidebar-name").textContent = data.display_name;
      document.querySelector("#profile-subtitle").textContent = "@" + data.username + " · " + data.city + " · Côte d’Ivoire";
      document.querySelector("#profile-bio").textContent = data.bio || "Ajoutez une courte présentation.";
      const labels = { friendship: "Amitié", dating: "Rencontres", networking: "Réseautage", discussion: "Discussions", events: "Événements" };
      document.querySelector("#profile-interests").textContent = (data.interested_in || []).map(value => labels[value] || value).join(" · ") || "Aucun centre d’intérêt ajouté.";
      document.querySelector("#profile-visibility").textContent = data.is_discoverable ? "Découvrable (après approbation)" : "Non visible dans la découverte";
      document.querySelectorAll(".avatar-user").forEach(el => { el.textContent = data.display_name.trim().charAt(0).toUpperCase() || "B"; });
      closeProfileEditor();
      window.BaddieLinkUI?.toast("Votre profil a été mis à jour.");
      if (data.moderation_status !== "approved") {
        window.BaddieLinkUI?.toast("Profil enregistré. Il restera invisible jusqu’à son approbation.");
      }
    } catch (error) {
      console.error("BaddieLink profile update failed:", error);
      const text = error.code === "23505"
        ? "Ce nom d’utilisateur est déjà utilisé."
        : (error.message || "La mise à jour du profil a échoué.");
      showFeedback(text, true);
    } finally {
      save.disabled = false;
      save.textContent = "Enregistrer";
    }
  });

  async function submitAuth(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (busy) return;
    setBusy(true);

    try {
      const email = emailInput.value.trim().toLowerCase();
      const password = passwordInput.value;
      const mode = window.__baddielinkMode || "signup";

      if (!email || password.length < 8) {
        throw new Error("Vérifiez votre adresse e-mail et votre mot de passe (8 caractères minimum).");
      }

      if (mode === "signup") {
        const displayName = nameInput.value.trim();
        const dob = dobInput.value;
        if (!displayName) throw new Error("Veuillez saisir un nom affiché.");
        if (!terms.checked) throw new Error("Vous devez accepter les conditions d’utilisation.");
        const age = calculateAge(dob);
        if (age < 18 || age > 100) {
          throw new Error("BaddieLink est réservé aux personnes âgées de 18 à 100 ans.");
        }

        const { data, error } = await client.auth.signUp({
          email,
          password,
          options: {
            data: {
              display_name: displayName,
              username: displayName.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9_]/g, "").slice(0, 18)
            },
            emailRedirectTo: window.location.origin + window.location.pathname
          }
        });
        if (error) throw error;

        if (!data.session) {
          message("Compte créé. Consultez votre boîte e-mail pour confirmer votre adresse. Après confirmation, connectez-vous pour enregistrer votre déclaration de majorité.");
          return;
        }

        const { error: ageError } = await client.rpc("confirm_adult_status", {
          p_date_of_birth: dob
        });
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
      console.error("BaddieLink authentication error:", error);
      message(error.message || "Une erreur est survenue. Réessayez.", true);
    } finally {
      setBusy(false);
    }
  }

  if (!config || !supabaseFactory) {
    console.error("BaddieLink authentication could not initialize.");
    if (submit) submit.disabled = true;
    message("Le service de connexion est indisponible. Rechargez la page ou réessayez plus tard.", true);
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

  form.addEventListener("submit", submitAuth, true);

  client.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT") {
      window.BaddieLinkUI?.showWelcome();
    }
  });

  (async () => {
    const { data, error } = await client.auth.getSession();
    if (error) {
      console.error("Unable to restore BaddieLink session:", error);
      message("Impossible de restaurer votre session. Veuillez vous reconnecter.", true);
      showAuth("login");
      return;
    }
    if (!data.session) return;

    try {
      const adult = await ensureAdultDeclaration(data.session.user);
      if (adult) await enterAuthenticatedApp(data.session.user);
    } catch (restoreError) {
      console.error("BaddieLink session restore failed:", restoreError);
      showAuth("login");
      message("Votre session est active, mais votre profil doit être vérifié avant de continuer.", true);
    }
  })();
})();