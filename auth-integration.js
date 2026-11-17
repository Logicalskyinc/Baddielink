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
    await Promise.allSettled([loadProfilePhoto(), loadReputation(), loadEvents(), loadMyEvents()]);
    location.hash = "espace";
  }

  function setProfilePhoto(url) {
    document.querySelectorAll(".avatar-user").forEach(el => {
      el.textContent = "";
      el.style.backgroundImage = url ? "url('" + url.replace(/'/g, "%27") + "')" : "";
      el.classList.toggle("has-photo", Boolean(url));
    });
    const preview = document.querySelector("#profile-photo-preview");
    if (preview && url) preview.style.backgroundImage = "url('" + url.replace(/'/g, "%27") + "')";
  }

  async function loadProfilePhoto() {
    const { data, error } = await client.from("profile_photos")
      .select("object_path, moderation_status")
      .eq("user_id", currentUserId)
      .order("created_at", { ascending: false })
      .limit(1);
    if (error) throw error;
    const photo = data?.[0];
    if (!photo) return;
    const { data: signed, error: signedError } = await client.storage
      .from("baddielink-profile-photos").createSignedUrl(photo.object_path, 3600);
    if (signedError) throw signedError;
    if (signed?.signedUrl) setProfilePhoto(signed.signedUrl);
    const note = document.querySelector("#profile-photo-feedback");
    if (note && photo.moderation_status === "pending") {
      note.textContent = "Votre dernière photo est en attente de modération. Elle n’est pas encore visible publiquement.";
      note.classList.remove("hidden");
    }
  }

  async function loadReputation() {
    const { data, error } = await client.from("reputation_profiles")
      .select("score, rank").eq("user_id", currentUserId).maybeSingle();
    if (error) throw error;
    const labels = { beginner: "Débutant", novice: "Novice", intermediate: "Intermédiaire", advanced: "Avancé", expert: "Expert", legend: "Légende" };
    const target = document.querySelector("#profile-reputation");
    if (target) target.textContent = "☆☆☆☆☆ · " + (labels[data?.rank] || "Débutant") + " · " + (data?.score ?? 0) + " points";
  }

  async function uploadProfilePhoto() {
    const input = document.querySelector("#profile-photo-file");
    const button = document.querySelector("#upload-profile-photo");
    const note = document.querySelector("#profile-photo-feedback");
    const file = input?.files?.[0];
    const show = (text, isError = false) => {
      note.textContent = text;
      note.style.color = isError ? "#ff9aa8" : "#a7e0bd";
      note.classList.remove("hidden");
    };
    if (!file) return show("Choisissez d’abord une image.", true);
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) return show("Format non accepté. Utilisez JPEG, PNG ou WebP.", true);
    if (file.size > 5 * 1024 * 1024) return show("La photo dépasse la limite de 5 Mo.", true);
    const extension = ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" })[file.type];
    const path = currentUserId + "/" + crypto.randomUUID() + "." + extension;
    button.disabled = true;
    button.textContent = "Envoi…";
    try {
      const { error: uploadError } = await client.storage.from("baddielink-profile-photos")
        .upload(path, file, { contentType: file.type, upsert: false });
      if (uploadError) throw uploadError;
      const { error: rowError } = await client.from("profile_photos").insert({
        user_id: currentUserId, object_path: path, display_order: 0, moderation_status: "pending"
      });
      if (rowError) {
        await client.storage.from("baddielink-profile-photos").remove([path]);
        throw rowError;
      }
      const preview = document.querySelector("#profile-photo-preview");
      const localUrl = URL.createObjectURL(file);
      if (preview) preview.style.backgroundImage = "url('" + localUrl + "')";
      show("Photo envoyée. Elle restera privée pour les autres membres jusqu’à son approbation.");
      input.value = "";
    } catch (error) {
      console.error("BaddieLink profile photo upload failed:", error);
      show(error.message || "L’envoi de la photo a échoué.", true);
    } finally {
      button.disabled = false;
      button.textContent = "Envoyer la photo";
    }
  }

  const eventCategoryLabels = { concert: "Concert", party: "Soirée", exhibition: "Exposition", networking: "Réseautage", community: "Communauté", culture: "Culture", sports: "Sport", other: "Autre" };
  function eventNode(tag, className, value) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (value !== undefined) el.textContent = value;
    return el;
  }
  function formatEventDate(value) {
    return new Intl.DateTimeFormat("fr-FR", { dateStyle: "medium", timeStyle: "short", timeZone: "Africa/Abidjan" }).format(new Date(value));
  }

  async function loadEvents() {
    const list = document.querySelector("#events-list");
    if (!list) return;
    list.replaceChildren(eventNode("p", "discover-note", "Chargement des événements…"));
    try {
      let query = client.from("events").select("id,title,description,category,organizer_name,city,district,venue_name,address,starts_at,ends_at,entry_fee_xof,status")
        .eq("status", "published").gte("starts_at", new Date().toISOString()).order("starts_at", { ascending: true }).limit(50);
      const city = document.querySelector("#event-city-filter")?.value;
      const category = document.querySelector("#event-category-filter")?.value;
      if (city) query = query.eq("city", city);
      if (category) query = query.eq("category", category);
      const [{ data: events, error }, { data: interests, error: interestError }] = await Promise.all([
        query,
        client.from("event_interests").select("event_id").eq("user_id", currentUserId)
      ]);
      if (error) throw error;
      if (interestError) throw interestError;
      const interested = new Set((interests || []).map(row => row.event_id));
      list.replaceChildren();
      if (!events?.length) {
        list.append(eventNode("p", "discover-note", "Aucun événement publié ne correspond à ces filtres pour le moment."));
        return;
      }
      events.forEach(event => {
        const card = eventNode("article", "event-card");
        const meta = eventNode("div", "event-meta", (eventCategoryLabels[event.category] || "Événement") + " · " + event.city + (event.district ? " · " + event.district : ""));
        const title = eventNode("h3", "", event.title);
        const desc = eventNode("p", "event-description", event.description);
        const date = eventNode("p", "event-detail", "📅 " + formatEventDate(event.starts_at));
        const venue = eventNode("p", "event-detail", "⌖ " + event.venue_name + " · " + event.address);
        const organizer = eventNode("p", "event-detail", "Organisé par " + event.organizer_name);
        const fee = eventNode("p", "event-detail", event.entry_fee_xof > 0 ? "Entrée : " + Number(event.entry_fee_xof).toLocaleString("fr-FR") + " XOF" : "Entrée gratuite");
        const action = eventNode("button", "button button-outline event-interest", interested.has(event.id) ? "Ne plus suivre" : "Intéressé(e)");
        action.type = "button";
        action.addEventListener("click", async () => {
          action.disabled = true;
          try {
            if (interested.has(event.id)) {
              const { error: removeError } = await client.from("event_interests").delete().eq("event_id", event.id).eq("user_id", currentUserId);
              if (removeError) throw removeError;
              interested.delete(event.id);
              action.textContent = "Intéressé(e)";
            } else {
              const { error: addError } = await client.from("event_interests").insert({ event_id: event.id, user_id: currentUserId });
              if (addError) throw addError;
              interested.add(event.id);
              action.textContent = "Ne plus suivre";
            }
            loadMyEvents();
          } catch (error) {
            window.BaddieLinkUI?.toast(error.message || "Impossible de modifier votre intérêt.", true);
          } finally { action.disabled = false; }
        });
        card.append(meta, title, desc, date, venue, organizer, fee, action);
        list.append(card);
      });
    } catch (error) {
      console.error("BaddieLink events load failed:", error);
      list.replaceChildren(eventNode("p", "discover-note", "Impossible de charger les événements. Réessayez."));
    }
  }

  async function loadMyEvents() {
    const target = document.querySelector("#my-events-list");
    if (!target) return;
    try {
      const { data, error } = await client.from("event_interests")
        .select("created_at, events(id,title,starts_at,city,status)")
        .eq("user_id", currentUserId).order("created_at", { ascending: false }).limit(30);
      if (error) throw error;
      target.replaceChildren();
      const rows = (data || []).filter(row => row.events);
      if (!rows.length) {
        target.append(eventNode("p", "muted", "Vous ne suivez encore aucun événement."));
        return;
      }
      rows.forEach(row => {
        const event = row.events;
        const item = eventNode("p", "my-event-item", event.title + " · " + formatEventDate(event.starts_at) + " · " + event.city);
        target.append(item);
      });
    } catch (error) {
      console.error("BaddieLink personal events load failed:", error);
      target.textContent = "Impossible de charger vos événements.";
    }
  }

  async function submitEvent(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = document.querySelector("#event-create-submit");
    const feedback = document.querySelector("#event-create-feedback");
    const show = (text, isError = false) => {
      feedback.textContent = text;
      feedback.style.color = isError ? "#ff9aa8" : "#a7e0bd";
      feedback.classList.remove("hidden");
    };
    const startsAt = new Date(form.elements.starts_at.value);
    const endsAt = form.elements.ends_at.value ? new Date(form.elements.ends_at.value) : null;
    if (!Number.isFinite(startsAt.getTime()) || startsAt <= new Date()) return show("Choisissez une date future valide.", true);
    if (endsAt && (!Number.isFinite(endsAt.getTime()) || endsAt <= startsAt)) return show("L’heure de fin doit être postérieure au début.", true);
    const payload = {
      created_by: currentUserId,
      title: form.elements.title.value.trim(),
      description: form.elements.description.value.trim(),
      category: form.elements.category.value,
      organizer_name: form.elements.organizer_name.value.trim(),
      city: form.elements.city.value.trim(),
      district: form.elements.district.value.trim() || null,
      venue_name: form.elements.venue_name.value.trim(),
      address: form.elements.address.value.trim(),
      starts_at: startsAt.toISOString(),
      ends_at: endsAt ? endsAt.toISOString() : null,
      entry_fee_xof: Number(form.elements.entry_fee_xof.value),
      status: "pending_review"
    };
    if (payload.title.length < 3 || payload.description.length < 10 || !Number.isSafeInteger(payload.entry_fee_xof) || payload.entry_fee_xof < 0) return show("Vérifiez le titre, la description et le tarif.", true);
    button.disabled = true;
    button.textContent = "Envoi…";
    try {
      const { data: organizer, error: organizerError } = await client.from("event_organizers")
        .select("status").eq("user_id", currentUserId).maybeSingle();
      if (organizerError) throw organizerError;
      if (["approved", "trusted"].includes(organizer?.status)) payload.status = "published";
      const { error } = await client.from("events").insert(payload);
      if (error) throw error;
      form.reset();
      form.elements.city.value = "Abidjan";
      show(payload.status === "published" ? "Événement publié." : "Événement envoyé. Il sera visible après modération.");
      await loadEvents();
    } catch (error) {
      console.error("BaddieLink event submission failed:", error);
      show(error.message || "L’envoi de l’événement a échoué.", true);
    } finally {
      button.disabled = false;
      button.textContent = "Envoyer l’événement";
    }
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
    loadProfilePhoto().catch(error => console.warn("Profile photo preview unavailable:", error));
  }

  function closeProfileEditor() {
    document.querySelector("#profile-editor-modal")?.classList.add("hidden");
  }

  document.querySelector("#upload-profile-photo")?.addEventListener("click", uploadProfilePhoto);
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

  document.querySelector("#event-create-form")?.addEventListener("submit", submitEvent);
  document.querySelector("#refresh-events")?.addEventListener("click", loadEvents);
  document.querySelector("#event-city-filter")?.addEventListener("change", loadEvents);
  document.querySelector("#event-category-filter")?.addEventListener("change", loadEvents);

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