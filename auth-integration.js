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


  let isBaddieLinkAdmin = false;
  let activeAdminTab = "overview";

  function adminNode(tag, className, value) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (value !== undefined && value !== null) el.textContent = String(value);
    return el;
  }

  function adminButton(label, action, id, reasonPrompt = false) {
    const button = adminNode("button", "button button-outline admin-action", label);
    button.type = "button";
    button.addEventListener("click", async () => {
      if (!isBaddieLinkAdmin) return;
      const reason = reasonPrompt ? (window.prompt("Motif de cette décision (facultatif) :") || "") : "";
      button.disabled = true;
      try {
        const { error } = await client.rpc(action, { ...id, p_reason: reason });
        if (error) throw error;
        window.BaddieLinkUI?.toast("Action enregistrée.");
        await loadAdminTab(activeAdminTab);
      } catch (error) {
        console.error("BaddieLink admin action failed:", error);
        window.BaddieLinkUI?.toast(error.message || "Action administrative impossible.", true);
      } finally {
        button.disabled = false;
      }
    });
    return button;
  }

  function adminCard(title, subtitle, detail) {
    const card = adminNode("article", "admin-item");
    const head = adminNode("div", "admin-item-head");
    const copy = adminNode("div", "admin-item-copy");
    copy.append(adminNode("h3", "", title), adminNode("p", "", subtitle));
    head.append(copy);
    card.append(head);
    if (detail) card.append(adminNode("p", "admin-item-detail", detail));
    return { card, head };
  }

  function setAdminStatus(text, isError = false) {
    const status = document.querySelector("#admin-console-status");
    if (!status) return;
    status.textContent = text;
    status.classList.toggle("error", isError);
  }

  function showAdminConsole() {
    if (!isBaddieLinkAdmin) return;
    document.querySelectorAll(".view").forEach(el => el.classList.remove("active"));
    document.querySelector("#admin-console")?.classList.remove("hidden");
    document.querySelector("#mobile-bottom-nav")?.classList.add("hidden");
    document.querySelector(".mobile-bottom-nav")?.classList.add("hidden");
    document.querySelector("#view-kicker").textContent = "ESPACE PRIVÉ";
    document.querySelector("#view-title").textContent = "Administration";
    document.querySelector("#view-description").textContent = "Console de gestion et de modération BaddieLink.";
    document.querySelector("#admin-mode-toggle").textContent = "Membre";
    document.querySelector("#admin-mode-toggle").title = "Revenir à l’espace membre";
    location.hash = "admin";
    loadAdminTab(activeAdminTab);
  }

  function showMemberWorkspace() {
    document.querySelector("#admin-console")?.classList.add("hidden");
    document.querySelector(".mobile-bottom-nav")?.classList.remove("hidden");
    document.querySelector("#admin-mode-toggle").textContent = "⚙";
    document.querySelector("#admin-mode-toggle").title = "Ouvrir la console d’administration";
    window.BaddieLinkUI?.showView("discover");
    if (isBaddieLinkAdmin && location.hash === "#admin") showAdminConsole();\n    else location.hash = "espace";
  }

  async function loadAdminTab(tab) {
    if (!isBaddieLinkAdmin) return;
    activeAdminTab = tab;
    document.querySelectorAll("[data-admin-tab]").forEach(button => button.classList.toggle("active", button.dataset.adminTab === tab));
    const queue = document.querySelector("#admin-queue");
    const metrics = document.querySelector("#admin-metrics");
    if (!queue || !metrics) return;
    queue.replaceChildren();
    metrics.replaceChildren();
    setAdminStatus("Chargement…");
    try {
      if (tab === "overview") {
        const tables = [
          ["Événements à examiner", "events", "status", "pending_review"],
          ["Demandes organisateur", "organizer_applications", "status", "pending"],
          ["Photos à modérer", "profile_photos", "moderation_status", "pending"],
          ["Signalements d’événements", "event_reports", "status", "pending"],
          ["Signalements de membres", "reports", "status", "open"],
          ["Profils en attente", "profiles", "moderation_status", "pending"]
        ];
        const counts = await Promise.all(tables.map(async item => {
          const { count, error } = await client.from(item[1]).select("id", { count: "exact", head: true }).eq(item[2], item[3]);
          if (error) throw error;
          return { label: item[0], count: count || 0 };
        }));
        counts.forEach(item => {
          const metric = adminNode("div", "admin-metric");
          metric.append(adminNode("strong", "", item.count), adminNode("span", "", item.label));
          metrics.append(metric);
        });
        const intro = adminNode("div", "admin-empty");
        intro.append(adminNode("h3", "", "Centre de contrôle"), adminNode("p", "", "Sélectionnez une file pour examiner les éléments. Chaque décision de modération est enregistrée dans le journal d’audit."));
        queue.append(intro);
        setAdminStatus("Données administratives chargées.");
        return;
      }

      if (tab === "events") {
        const { data, error } = await client.from("events").select("id,title,description,category,organizer_name,city,district,venue_name,address,starts_at,entry_fee_xof,created_by,created_at").eq("status","pending_review").order("created_at",{ascending:true}).limit(50);
        if (error) throw error;
        (data || []).forEach(item => {
          const {card,head}=adminCard(item.title, item.organizer_name+" · "+item.category, item.city+(item.district ? " · "+item.district : "")+" · "+item.venue_name+" · "+new Date(item.starts_at).toLocaleString("fr-FR"));
          head.append(adminNode("span","admin-status-pill","À examiner"));
          card.append(adminNode("p","admin-item-detail",item.description));
          const actions=adminNode("div","admin-item-actions");
          actions.append(adminButton("Publier","admin_review_event",{p_event_id:item.id,p_decision:"publish"},true),adminButton("Rejeter","admin_review_event",{p_event_id:item.id,p_decision:"reject"},true));
          card.append(actions); queue.append(card);
        });
      } else if (tab === "organizers") {
        const { data, error } = await client.from("organizer_applications").select("id,user_id,organization_name,organization_type,website_url,description,created_at").eq("status","pending").order("created_at",{ascending:true}).limit(50);
        if (error) throw error;
        (data || []).forEach(item => {
          const {card,head}=adminCard(item.organization_name,item.organization_type+" · Compte "+item.user_id.slice(0,8),item.description);
          if(item.website_url) card.append(adminNode("p","admin-item-detail",item.website_url));
          head.append(adminNode("span","admin-status-pill","En attente"));
          const actions=adminNode("div","admin-item-actions");
          actions.append(adminButton("Approuver","admin_review_organizer_application",{p_application_id:item.id,p_decision:"approve"},true),adminButton("Rejeter","admin_review_organizer_application",{p_application_id:item.id,p_decision:"reject"},true));
          card.append(actions); queue.append(card);
        });
      } else if (tab === "photos") {
        const { data, error } = await client.from("profile_photos").select("id,user_id,object_path,created_at").eq("moderation_status","pending").order("created_at",{ascending:true}).limit(40);
        if (error) throw error;
        for (const item of (data || [])) {
          const {card,head}=adminCard("Photo de profil","Compte "+item.user_id.slice(0,8),new Date(item.created_at).toLocaleString("fr-FR"));
          const {data:signed,error:signedError}=await client.storage.from("baddielink-profile-photos").createSignedUrl(item.object_path,600);
          if(!signedError && signed?.signedUrl){const img=adminNode("img","admin-photo-preview");img.src=signed.signedUrl;img.alt="Photo soumise à modération";card.append(img);}
          head.append(adminNode("span","admin-status-pill","En attente"));
          const actions=adminNode("div","admin-item-actions");
          actions.append(adminButton("Approuver","admin_review_profile_photo",{p_photo_id:item.id,p_decision:"approve"},true),adminButton("Rejeter","admin_review_profile_photo",{p_photo_id:item.id,p_decision:"reject"},true));
          card.append(actions); queue.append(card);
        }
      } else if (tab === "event-reports") {
        const { data, error } = await client.from("event_reports").select("id,event_id,reporter_id,reason,details,created_at,events(title)").eq("status","pending").order("created_at",{ascending:true}).limit(50);
        if (error) throw error;
        (data || []).forEach(item => {
          const {card,head}=adminCard(item.events?.title || "Événement signalé",item.reason+" · Compte "+item.reporter_id.slice(0,8),item.details || "Aucun détail fourni.");
          head.append(adminNode("span","admin-status-pill","Nouveau"));
          const actions=adminNode("div","admin-item-actions");
          actions.append(adminButton("Marquer examiné","admin_review_event_report",{p_report_id:item.id,p_decision:"reviewed"},true),adminButton("Classer sans suite","admin_review_event_report",{p_report_id:item.id,p_decision:"dismissed"},true));
          card.append(actions); queue.append(card);
        });
      } else if (tab === "member-reports") {
        const { data, error } = await client.from("reports").select("id,reporter_id,reported_user_id,message_id,reason,details,status,created_at").in("status",["open","reviewing"]).order("created_at",{ascending:true}).limit(50);
        if (error) throw error;
        (data || []).forEach(item => {
          const {card,head}=adminCard("Signalement de membre",item.reason+" · "+(item.reported_user_id ? "Compte "+item.reported_user_id.slice(0,8) : "Message "+String(item.message_id).slice(0,8)),item.details || "Aucun détail fourni.");
          head.append(adminNode("span","admin-status-pill",item.status));
          const actions=adminNode("div","admin-item-actions");
          actions.append(adminButton("En cours","admin_review_member_report",{p_report_id:item.id,p_decision:"reviewing"},true),adminButton("Action prise","admin_review_member_report",{p_report_id:item.id,p_decision:"actioned"},true),adminButton("Clôturer","admin_review_member_report",{p_report_id:item.id,p_decision:"closed"},true));
          card.append(actions); queue.append(card);
        });
      } else if (tab === "members") {
        const { data, error } = await client.from("profiles").select("id,username,display_name,city,moderation_status,created_at").order("created_at",{ascending:false}).limit(50);
        if (error) throw error;
        (data || []).forEach(item => {
          const {card,head}=adminCard(item.display_name+" (@"+item.username+")",item.city+" · "+item.id.slice(0,8), "Statut : "+item.moderation_status+" · Inscription : "+new Date(item.created_at).toLocaleDateString("fr-FR"));
          head.append(adminNode("span","admin-status-pill",item.moderation_status));
          const actions=adminNode("div","admin-item-actions");
          if(item.moderation_status!=="approved") actions.append(adminButton("Approuver","admin_review_member",{p_user_id:item.id,p_decision:"approve"},true));
          if(item.moderation_status!=="restricted") actions.append(adminButton("Restreindre","admin_review_member",{p_user_id:item.id,p_decision:"restrict"},true));
          if(item.moderation_status!=="removed") actions.append(adminButton("Retirer","admin_review_member",{p_user_id:item.id,p_decision:"remove"},true));
          card.append(actions); queue.append(card);
        });
      } else if (tab === "audit") {
        const { data, error } = await client.from("admin_audit_log").select("id,actor_id,action,target_type,target_id,reason,created_at").order("created_at",{ascending:false}).limit(100);
        if (error) throw error;
        (data || []).forEach(item => {
          const {card,head}=adminCard(item.action.replaceAll("_"," "),item.target_type+" · "+item.target_id.slice(0,8),new Date(item.created_at).toLocaleString("fr-FR")+(item.reason ? " · "+item.reason : ""));
          head.append(adminNode("span","admin-status-pill","Journalisé")); queue.append(card);
        });
      }
      if (!queue.children.length) queue.append(adminNode("div","admin-empty","Aucun élément dans cette file."));
      setAdminStatus("File actualisée · "+queue.children.length+" élément(s).");
    } catch (error) {
      console.error("BaddieLink admin queue failed:", error);
      setAdminStatus(error.message || "Impossible de charger cette file.", true);
      queue.replaceChildren(adminNode("div","admin-empty","Les données n’ont pas pu être chargées. Vérifiez vos autorisations puis réessayez."));
    }
  }

  document.querySelector("#admin-mode-toggle")?.addEventListener("click", () => {
    if (document.querySelector("#admin-console")?.classList.contains("hidden")) showAdminConsole();
    else showMemberWorkspace();
  });
  document.querySelector("#admin-back-member")?.addEventListener("click", showMemberWorkspace);
  document.querySelectorAll("[data-admin-tab]").forEach(button => button.addEventListener("click", () => loadAdminTab(button.dataset.adminTab)));

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


    const { data: adminAccess, error: adminAccessError } = await client.rpc("is_baddielink_admin");
    isBaddieLinkAdmin = !adminAccessError && adminAccess === true;
    const adminToggle = document.querySelector("#admin-mode-toggle");
    if (adminToggle) adminToggle.classList.toggle("hidden", !isBaddieLinkAdmin);
\n    const displayName = profile.display_name || user.email || "Membre BaddieLink";
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
    await Promise.allSettled([loadProfilePhoto(), loadReputation(), loadEvents(), loadMyEvents(), loadOrganizerApplication()]);
    location.hash = "espace";
    const sharedEventId = new URLSearchParams(location.search).get("event");
    if (sharedEventId) {
      document.querySelector('[data-discover-section="exhibitions"]')?.click();
      requestAnimationFrame(() => document.querySelector("#event-" + CSS.escape(sharedEventId))?.scrollIntoView({ behavior: "smooth", block: "center" }));
    }
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
      .eq("moderation_status", "approved")
      .order("created_at", { ascending: false })
      .limit(1);
    if (error) throw error;
    const photo = data?.[0];
    if (!photo) {
      document.querySelectorAll(".avatar-user").forEach(el => { el.style.backgroundImage = ""; el.classList.remove("has-photo"); });
      return;
    }
    const { data: signed, error: signedError } = await client.storage
      .from("baddielink-profile-photos").createSignedUrl(photo.object_path, 3600);
    if (signedError) throw signedError;
    if (signed?.signedUrl) setProfilePhoto(signed.signedUrl);
  }

  async function loadReputation() {
    const { data, error } = await client.from("reputation_profiles")
      .select("score, rank").eq("user_id", currentUserId).maybeSingle();
    if (error) throw error;
    const labels = { beginner: "Débutant", novice: "Novice", intermediate: "Intermédiaire", advanced: "Avancé", expert: "Expert", legend: "Légende" };
    const target = document.querySelector("#profile-reputation");
    if (target) target.textContent = "☆☆☆☆☆ · " + (labels[data?.rank] || "Débutant") + " · " + (data?.score ?? 0) + " points";
  }


  function previewImageInput(input, preview, note, messageText) {
    const file = input?.files?.[0];
    if (!file || !preview || !note) return;
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 5 * 1024 * 1024) {
      note.textContent = "Choisissez une image JPEG, PNG ou WebP de 5 Mo maximum.";
      note.style.color = "#ff9aa8";
      note.classList.remove("hidden");
      input.value = "";
      return;
    }
    preview.src = URL.createObjectURL(file);
    preview.classList.remove("hidden");
    note.textContent = messageText;
    note.style.color = "#a7e0bd";
    note.classList.remove("hidden");
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
        user_id: currentUserId, object_path: path, moderation_status: "pending"
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
      let query = client.from("events").select("id,created_by,title,description,category,organizer_name,city,district,venue_name,address,starts_at,ends_at,entry_fee_xof,status,event_image_path")
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
        card.id = "event-" + event.id;
        if (event.event_image_path) loadEventImage(event.event_image_path).then(url => { if (url) { const img = eventNode("img", "event-card-image"); img.src = url; img.alt = "Couverture : " + event.title; card.prepend(img); } });
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

        const actions = eventNode("div", "event-card-actions");
        const share = eventNode("button", "button button-outline event-secondary-action", "Partager");
        share.type = "button";
        share.addEventListener("click", async () => {
          const shareData = { title: event.title, text: event.title + " · " + event.venue_name + " · " + formatEventDate(event.starts_at), url: location.origin + location.pathname + "?event=" + encodeURIComponent(event.id) + "#espace" };
          try {
            if (navigator.share) await navigator.share(shareData);
            else if (navigator.clipboard?.writeText) {
              await navigator.clipboard.writeText(shareData.url);
              window.BaddieLinkUI?.toast("Lien de l’événement copié.");
            } else window.BaddieLinkUI?.toast("Le partage n’est pas disponible sur cet appareil.", true);
          } catch (error) {
            if (error.name !== "AbortError") window.BaddieLinkUI?.toast("Impossible de partager cet événement.", true);
          }
        });
        actions.append(share);
        if (event.created_by !== currentUserId) {
          const report = eventNode("button", "button button-outline event-secondary-action", "Signaler");
          report.type = "button";
          report.addEventListener("click", () => {
            if (card.querySelector(".event-report-form")) return;
            const reportForm = eventNode("form", "event-report-form");
            const reason = eventNode("select", "");
            reason.name = "reason";
            [["spam","Spam"],["misleading","Informations trompeuses"],["unsafe","Événement dangereux"],["harassment","Harcèlement"],["other","Autre"]].forEach(([value,label]) => {
              const option = eventNode("option", "", label); option.value = value; reason.append(option);
            });
            const details = eventNode("textarea", "");
            details.name = "details"; details.maxLength = 1000; details.rows = 2; details.placeholder = "Détails facultatifs";
            const send = eventNode("button", "button button-outline event-secondary-action", "Envoyer le signalement"); send.type = "submit";
            const cancel = eventNode("button", "button button-outline event-secondary-action", "Annuler"); cancel.type = "button";
            cancel.addEventListener("click", () => reportForm.remove());
            const feedback = eventNode("p", "form-feedback");
            reportForm.append(reason, details, send, cancel, feedback);
            reportForm.addEventListener("submit", async submit => {
              submit.preventDefault(); send.disabled = true;
              try {
                const { error } = await client.from("event_reports").insert({
                  event_id: event.id, reporter_id: currentUserId,
                  reason: reason.value, details: details.value.trim() || null
                });
                if (error) throw error;
                feedback.textContent = "Signalement transmis à l’équipe de modération.";
                report.disabled = true; report.textContent = "Signalé";
                reportForm.querySelectorAll("select,textarea,button").forEach(control => { control.disabled = true; });
              } catch (error) {
                feedback.textContent = error.code === "23505" ? "Vous avez déjà signalé cet événement." : (error.message || "Le signalement a échoué.");
                send.disabled = false;
              }
            });
            card.append(reportForm);
          });
          actions.append(report);
        }
        card.append(meta, title, desc, date, venue, organizer, fee, action, actions);
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
      const [{ data: interestRows, error: interestError }, { data: createdRows, error: createdError }, { data: organizer, error: organizerError }] = await Promise.all([
        client.from("event_interests").select("created_at, events(id,title,starts_at,city,status)").eq("user_id", currentUserId).order("created_at", { ascending: false }).limit(30),
        client.from("events").select("id,title,starts_at,city,status").eq("created_by", currentUserId).order("created_at", { ascending: false }).limit(30),
        client.from("event_organizers").select("status").eq("user_id", currentUserId).maybeSingle()
      ]);
      if (interestError) throw interestError;
      if (createdError) throw createdError;
      if (organizerError) throw organizerError;
      target.replaceChildren();
      const interestedEvents = (interestRows || []).filter(row => row.events);
      const submittedEvents = createdRows || [];
      const heading1 = eventNode("h4", "my-events-heading", "Événements suivis");
      target.append(heading1);
      if (!interestedEvents.length) target.append(eventNode("p", "muted", "Vous ne suivez encore aucun événement."));
      interestedEvents.forEach(row => target.append(eventNode("p", "my-event-item", row.events.title + " · " + formatEventDate(row.events.starts_at) + " · " + row.events.city)));
      target.append(eventNode("h4", "my-events-heading", "Événements proposés"));
      if (!submittedEvents.length) target.append(eventNode("p", "muted", "Vous n’avez proposé aucun événement."));
      submittedEvents.forEach(item => {
        const wrap = eventNode("div", "my-event-submission");
        const statusLabels = { pending_review: "En attente de modération", published: "Publié", rejected: "Refusé", cancelled: "Annulé", completed: "Terminé" };
        wrap.append(eventNode("p", "my-event-item", item.title + " · " + formatEventDate(item.starts_at) + " · " + (statusLabels[item.status] || item.status)));
        if (item.status === "pending_review" || (item.status === "published" && ["approved","trusted"].includes(organizer?.status))) {
          const action = eventNode("button", "button button-outline event-secondary-action", item.status === "pending_review" && ["approved","trusted"].includes(organizer?.status) ? "Publier maintenant" : "Retirer l’événement");
          action.type = "button";
          action.addEventListener("click", async () => {
            action.disabled = true;
            try {
              const nextStatus = item.status === "pending_review" && ["approved","trusted"].includes(organizer?.status) ? "published" : "cancelled";
              const { error } = await client.from("events").update({ status: nextStatus }).eq("id", item.id).eq("created_by", currentUserId);
              if (error) throw error;
              await Promise.all([loadMyEvents(), loadEvents()]);
            } catch (error) {
              window.BaddieLinkUI?.toast(error.message || "Impossible de modifier cet événement.", true);
              action.disabled = false;
            }
          });
          wrap.append(action);
        }
        target.append(wrap);
      });
    } catch (error) {
      console.error("BaddieLink personal events load failed:", error);
      target.textContent = "Impossible de charger vos événements.";
    }
  }

  async function uploadEventImage(file) {
    if (!file) return null;
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 5 * 1024 * 1024) {
      throw new Error("L’image doit être au format JPEG, PNG ou WebP et faire 5 Mo maximum.");
    }
    const extension = ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" })[file.type];
    const path = currentUserId + "/" + crypto.randomUUID() + "." + extension;
    const { error } = await client.storage.from("baddielink-event-images")
      .upload(path, file, { contentType: file.type, upsert: false });
    if (error) throw error;
    return path;
  }

  async function loadEventImage(path) {
    if (!path) return null;
    const { data, error } = await client.storage.from("baddielink-event-images").createSignedUrl(path, 3600);
    if (error) {
      console.warn("Event image not accessible:", error);
      return null;
    }
    return data?.signedUrl || null;
  }


  async function loadOrganizerApplication() {
    const form = document.querySelector("#organizer-application-form");
    if (!form) return;
    const feedback = document.querySelector("#organizer-application-feedback");
    try {
      const [{ data: application, error }, { data: organizer, error: organizerError }] = await Promise.all([
        client.from("organizer_applications").select("organization_name,status").eq("user_id", currentUserId).maybeSingle(),
        client.from("event_organizers").select("organization_name,status").eq("user_id", currentUserId).maybeSingle()
      ]);
      if (error) throw error;
      if (organizerError) throw organizerError;
      if (organizer && ["approved","trusted"].includes(organizer.status)) {
        feedback.textContent = "Votre compte organisateur est " + (organizer.status === "trusted" ? "de confiance." : "vérifié.") + " Vous pouvez publier directement vos événements.";
        feedback.classList.remove("hidden");
        form.querySelectorAll("input,select,textarea,button").forEach(el => { el.disabled = true; });
      } else if (application) {
        feedback.textContent = application.status === "pending"
          ? "Demande reçue pour " + application.organization_name + ". Elle est en attente de vérification."
          : application.status === "approved" ? "Votre demande est approuvée. Actualisez la page pour voir vos droits organisateur."
          : "Votre demande précédente a été refusée. Contactez l’équipe d’assistance si vous souhaitez demander un nouvel examen.";
        feedback.classList.remove("hidden");
        form.querySelectorAll("input,select,textarea,button").forEach(el => { el.disabled = true; });
      }
    } catch (error) {
      console.warn("Organizer application status unavailable:", error);
    }
  }

  async function submitOrganizerApplication(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = document.querySelector("#organizer-application-submit");
    const feedback = document.querySelector("#organizer-application-feedback");
    const website = form.elements.website_url.value.trim();
    if (website) {
      try {
        const parsed = new URL(website);
        if (!["http:", "https:"].includes(parsed.protocol)) throw new Error();
      } catch {
        feedback.textContent = "Entrez une adresse web valide commençant par https://.";
        feedback.classList.remove("hidden");
        return;
      }
    }
    button.disabled = true;
    try {
      const { error } = await client.from("organizer_applications").insert({
        user_id: currentUserId,
        organization_name: form.elements.organization_name.value.trim(),
        organization_type: form.elements.organization_type.value,
        website_url: website || null,
        description: form.elements.description.value.trim()
      });
      if (error) throw error;
      feedback.textContent = "Demande envoyée. Elle sera examinée par l’équipe BaddieLink.";
      feedback.classList.remove("hidden");
      form.querySelectorAll("input,select,textarea,button").forEach(el => { el.disabled = true; });
    } catch (error) {
      feedback.textContent = error.code === "23505" ? "Une demande existe déjà pour ce compte." : (error.message || "Impossible d’envoyer la demande.");
      feedback.classList.remove("hidden");
      button.disabled = false;
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
    const imageFile = form.elements.event_image.files?.[0] || null;
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
      event_image_path: null,
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
      if (imageFile) payload.event_image_path = await uploadEventImage(imageFile);
      const { error } = await client.from("events").insert(payload);
      if (error) {
        if (payload.event_image_path) await client.storage.from("baddielink-event-images").remove([payload.event_image_path]);
        throw error;
      }
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


  document.querySelector("#event-image")?.addEventListener("change", event => {
    previewImageInput(
      event.target,
      document.querySelector("#event-image-preview"),
      document.querySelector("#event-create-feedback"),
      "Aperçu prêt. La couverture sera associée à votre événement."
    );
  });
  document.querySelector("#profile-photo-file")?.addEventListener("change", event => {
    const file = event.target.files?.[0];
    const preview = document.querySelector("#profile-photo-preview");
    const note = document.querySelector("#profile-photo-feedback");
    if (!file || !preview || !note) return;
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 5 * 1024 * 1024) {
      note.textContent = "Choisissez une image JPEG, PNG ou WebP de 5 Mo maximum.";
      note.style.color = "#ff9aa8";
      note.classList.remove("hidden");
      event.target.value = "";
      return;
    }
    preview.style.backgroundImage = "url('" + URL.createObjectURL(file) + "')";
    note.textContent = "Aperçu prêt. Appuyez sur « Envoyer la photo » pour la soumettre à la modération.";
    note.style.color = "#a7e0bd";
    note.classList.remove("hidden");
  });
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
  document.querySelector("#organizer-application-form")?.addEventListener("submit", submitOrganizerApplication);
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