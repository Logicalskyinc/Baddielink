(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const node = (tag, className, value) => {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (value !== undefined && value !== null) el.textContent = String(value);
    return el;
  };
  let client = null;
  let userId = null;
  let spaces = [];
  let memberships = new Map();
  let selectedSpaceId = null;
  let loading = false;

  function status(text, error = false) {
    const el = $("#salon-status");
    if (!el) return;
    el.textContent = text;
    el.classList.toggle("error", error);
  }

  function toast(text, error = false) {
    window.BaddieLinkUI?.toast(text, error);
    if (!window.BaddieLinkUI) status(text, error);
  }

  function slugify(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
      .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48);
  }

  function membershipLabel(row) {
    if (!row) return "Découvrir";
    if (row.status === "pending") return "Demande envoyée";
    if (row.status === "active") return row.role === "owner" ? "Propriétaire" : row.role === "moderator" ? "Modérateur" : "Membre";
    if (row.status === "banned") return "Accès refusé";
    return "Adhésion terminée";
  }

  function renderList() {
    const target = $("#salon-list");
    if (!target) return;
    target.replaceChildren();
    const term = ($("#salon-search")?.value || "").trim().toLocaleLowerCase("fr");
    const city = $("#salon-city-filter")?.value || "";
    const visible = spaces.filter(space => {
      const own = memberships.get(space.id);
      if (space.visibility === "private" && !own) return false;
      if (city && space.city !== city) return false;
      if (term && !(space.name + " " + space.description + " " + space.city).toLocaleLowerCase("fr").includes(term)) return false;
      return true;
    });
    if (!visible.length) {
      target.append(node("p", "discover-note", "Aucun salon ne correspond à votre recherche. Vous pouvez créer le premier."));
      return;
    }
    visible.forEach(space => {
      const card = node("article", "salon-card" + (space.id === selectedSpaceId ? " selected" : ""));
      const top = node("div", "salon-card-top");
      top.append(node("span", "salon-card-icon", "◉"), node("span", "salon-card-visibility", space.visibility === "private" ? "Privé" : "Public"));
      const title = node("h3", "", space.name);
      const copy = node("p", "salon-card-description", space.description || "Aucune description.");
      const meta = node("p", "salon-card-meta", space.city + " · " + (memberships.get(space.id)?.status === "active" ? "Membre" : space.join_policy === "approval" ? "Sur approbation" : space.join_policy === "invite_only" ? "Sur invitation" : "Accès libre"));
      const open = node("button", "button button-outline button-full", "Voir le salon");
      open.type = "button";
      open.addEventListener("click", () => selectSpace(space.id));
      card.append(top, title, copy, meta, open);
      target.append(card);
    });
  }

  function renderDetail(space, rows) {
    const target = $("#salon-detail");
    if (!target) return;
    target.replaceChildren();
    target.classList.remove("hidden");
    const own = memberships.get(space.id);
    const isOwner = own?.role === "owner" && own.status === "active";
    const isMember = own?.status === "active";
    const header = node("div", "salon-detail-head");
    const copy = node("div", "");
    copy.append(node("span", "discover-kicker", space.visibility === "private" ? "SALON PRIVÉ" : "SALON PUBLIC"),
      node("h2", "", space.name),
      node("p", "salon-card-meta", space.city + " · " + membershipLabel(own)));
    header.append(copy);
    target.append(header, node("p", "salon-detail-description", space.description || "Aucune description."));
    const controls = node("div", "salon-detail-actions");
    if (!own || own.status === "removed") {
      const join = node("button", "button button-primary", space.join_policy === "approval" ? "Demander à rejoindre" : "Rejoindre");
      join.type = "button";
      join.disabled = space.visibility === "private" || space.join_policy === "invite_only" || own?.status === "banned";
      join.addEventListener("click", () => joinSpace(space));
      controls.append(join);
    } else if (own.status === "pending") {
      controls.append(node("span", "salon-status-pill", "Demande en attente"));
    } else if (isMember && !isOwner) {
      const leave = node("button", "button button-outline", "Quitter le salon");
      leave.type = "button";
      leave.addEventListener("click", () => leaveSpace(space));
      controls.append(leave);
    }
    target.append(controls);

    if (isMember) {
      const memberSection = node("section", "salon-members");
      memberSection.append(node("h3", "", "Membres (" + rows.filter(row => row.status === "active").length + ")"));
      const list = node("div", "salon-member-list");
      rows.filter(row => row.status === "active").forEach(row => {
        const item = node("div", "salon-member-row");
        const identity = node("span", "", row.user_id === userId ? "Vous" : "Membre " + row.user_id.slice(0, 8));
        item.append(identity, node("span", "salon-status-pill", row.role === "owner" ? "Propriétaire" : row.role === "moderator" ? "Modérateur" : "Membre"));
        if (isOwner && row.user_id !== userId && row.role !== "owner") {
          const remove = node("button", "button button-outline", "Retirer");
          remove.type = "button";
          remove.addEventListener("click", () => {
            if (window.confirm("Retirer ce membre du salon ?")) updateMembership(space.id, row.user_id, { status: "removed" });
          });
          item.append(remove);
        }
        list.append(item);
      });
      memberSection.append(list);
      target.append(memberSection);
    }

    if (isOwner) {
      const pending = rows.filter(row => row.status === "pending");
      const manage = node("section", "salon-management");
      manage.append(node("h3", "", "Demandes d’adhésion"));
      if (!pending.length) manage.append(node("p", "discover-note", "Aucune demande en attente."));
      pending.forEach(row => {
        const item = node("div", "salon-member-row");
        item.append(node("span", "", "Compte " + row.user_id.slice(0, 8)));
        const actions = node("div", "salon-inline-actions");
        const approve = node("button", "button button-primary", "Accepter");
        approve.type = "button";
        approve.addEventListener("click", () => updateMembership(space.id, row.user_id, { status: "active", joined_at: new Date().toISOString() }));
        const reject = node("button", "button button-outline", "Refuser");
        reject.type = "button";
        reject.addEventListener("click", () => updateMembership(space.id, row.user_id, { status: "removed" }));
        actions.append(approve, reject); item.append(actions); manage.append(item);
      });
      const inviteForm = node("form", "salon-invite-form");
      const label = node("label", "", "Inviter par nom d’utilisateur");
      label.htmlFor = "salon-invite-username";
      const input = node("input");
      input.id = "salon-invite-username"; input.name = "username";
      input.placeholder = "nom_utilisateur"; input.minLength = 3; input.maxLength = 24; input.required = true;
      const invite = node("button", "button button-outline", "Inviter");
      invite.type = "submit";
      inviteForm.append(label, input, invite);
      inviteForm.addEventListener("submit", event => {
        event.preventDefault();
        inviteMember(space, input.value.trim().toLowerCase(), invite);
      });
      manage.append(node("h3", "", "Inviter un membre"), inviteForm);
      target.append(manage);
    }
    target.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  async function selectSpace(id) {
    const space = spaces.find(item => item.id === id);
    if (!space) return;
    selectedSpaceId = id;
    renderList();
    status("Chargement du salon…");
    try {
      const { data, error } = await client.from("space_memberships")
        .select("space_id,user_id,role,status,joined_at,created_at")
        .eq("space_id", id).order("created_at", { ascending: true }).limit(200);
      if (error) throw error;
      renderDetail(space, data || []);
      status("Salon chargé. La messagerie chiffrée n’est pas encore activée.");
    } catch (error) {
      console.error("Salon membership load failed:", error);
      status(error.message || "Impossible de charger les membres de ce salon.", true);
    }
  }

  async function load() {
    if (loading) return;
    client = window.baddielinkSupabase;
    if (!client) return;
    loading = true;
    try {
      const { data: sessionData, error: sessionError } = await client.auth.getSession();
      if (sessionError) throw sessionError;
      userId = sessionData?.session?.user?.id;
      if (!userId) return;
      status("Chargement des salons…");
      const [{ data: rows, error: spacesError }, { data: ownRows, error: membershipError }] = await Promise.all([
        client.from("spaces").select("id,name,slug,description,city,visibility,join_policy,owner_id,created_at")
          .eq("space_type", "salon").eq("status", "active").order("created_at", { ascending: false }).limit(100),
        client.from("space_memberships").select("space_id,user_id,role,status,joined_at")
          .eq("user_id", userId).limit(200)
      ]);
      if (spacesError) throw spacesError;
      if (membershipError) throw membershipError;
      spaces = rows || [];
      memberships = new Map((ownRows || []).map(row => [row.space_id, row]));
      renderList();
      const first = spaces.find(space => memberships.get(space.id)?.status === "active")
        || spaces.find(space => space.visibility === "public");
      if (selectedSpaceId && spaces.some(space => space.id === selectedSpaceId)) await selectSpace(selectedSpaceId);
      else if (first) await selectSpace(first.id);
      else {
        $("#salon-detail")?.classList.add("hidden");
        status("Aucun salon pour le moment. Créez-en un pour démarrer.");
      }
    } catch (error) {
      console.error("Salon discovery failed:", error);
      status(error.message || "Impossible de charger les salons. Réessayez.", true);
    } finally {
      loading = false;
    }
  }

  async function createSalon(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = $("#salon-create-submit");
    const name = form.elements.name.value.trim();
    const city = form.elements.city.value.trim();
    const visibility = form.elements.visibility.value;
    let joinPolicy = form.elements.join_policy.value;
    if (name.length < 3 || name.length > 60 || !city || city.length > 80) {
      status("Vérifiez le nom et la ville du salon.", true); return;
    }
    if (visibility === "private" && joinPolicy === "open") joinPolicy = "invite_only";
    const baseSlug = slugify(name);
    if (baseSlug.length < 3) { status("Choisissez un nom de salon plus précis.", true); return; }
    button.disabled = true;
    button.textContent = "Création…";
    try {
      const { data, error } = await client.from("spaces").insert({
        space_type: "salon",
        name,
        slug: baseSlug + "-" + crypto.randomUUID().slice(0, 8),
        description: form.elements.description.value.trim(),
        city,
        visibility,
        join_policy: joinPolicy,
        owner_id: userId
      }).select("id,name,slug,description,city,visibility,join_policy,owner_id,created_at").single();
      if (error) throw error;
      form.reset();
      form.elements.city.value = "Abidjan";
      form.elements.visibility.value = "public";
      form.elements.join_policy.value = "open";
      selectedSpaceId = data.id;
      window.BaddieLinkUI?.completeForm(form, "Salon créé. Vous en êtes le propriétaire.");
      toast("Salon créé. Vous en êtes le propriétaire.");
      await load();
    } catch (error) {
      console.error("Salon creation failed:", error);
      status(error.message || "La création du salon a échoué.", true);
    } finally {
      button.disabled = false;
      button.textContent = "Créer le salon";
    }
  }

  async function joinSpace(space) {
    const own = memberships.get(space.id);
    try {
      let result;
      if (own?.status === "removed") {
        const nextStatus = space.join_policy === "approval" ? "pending" : "active";
        result = await client.from("space_memberships").update({
          status: nextStatus,
          joined_at: nextStatus === "active" ? new Date().toISOString() : null
        }).eq("space_id", space.id).eq("user_id", userId);
      } else {
        const nextStatus = space.join_policy === "approval" ? "pending" : "active";
        result = await client.from("space_memberships").insert({
          space_id: space.id, user_id: userId, role: "member", status: nextStatus,
          joined_at: nextStatus === "active" ? new Date().toISOString() : null
        });
      }
      if (result.error) throw result.error;
      toast(space.join_policy === "approval" ? "Demande envoyée au propriétaire." : "Vous avez rejoint le salon.");
      await load();
    } catch (error) {
      console.error("Salon join failed:", error);
      toast(error.message || "Impossible de rejoindre ce salon.", true);
    }
  }

  async function leaveSpace(space) {
    if (!window.confirm("Quitter le salon « " + space.name + " » ?")) return;
    try {
      const { error } = await client.from("space_memberships")
        .update({ status: "removed" }).eq("space_id", space.id).eq("user_id", userId);
      if (error) throw error;
      selectedSpaceId = null;
      toast("Vous avez quitté le salon.");
      await load();
    } catch (error) {
      console.error("Salon leave failed:", error);
      toast(error.message || "Impossible de quitter ce salon.", true);
    }
  }

  async function updateMembership(spaceId, targetUserId, changes) {
    try {
      const { error } = await client.from("space_memberships").update(changes)
        .eq("space_id", spaceId).eq("user_id", targetUserId);
      if (error) throw error;
      toast(changes.status === "active" ? "Demande acceptée." : "Demande refusée.");
      await load();
      await selectSpace(spaceId);
    } catch (error) {
      console.error("Salon membership moderation failed:", error);
      toast(error.message || "Impossible de modifier cette adhésion.", true);
    }
  }

  async function inviteMember(space, username, button) {
    if (!/^[a-z0-9_]{3,24}$/.test(username)) {
      toast("Saisissez un nom d’utilisateur valide.", true); return;
    }
    button.disabled = true;
    try {
      const { data: profile, error: profileError } = await client.from("profiles")
        .select("id,username,display_name").eq("username", username)
        .eq("moderation_status", "approved").maybeSingle();
      if (profileError) throw profileError;
      if (!profile) throw new Error("Aucun membre approuvé trouvé avec ce nom d’utilisateur.");
      if (profile.id === userId) throw new Error("Vous êtes déjà propriétaire de ce salon.");
      const { error } = await client.from("space_memberships").insert({
        space_id: space.id, user_id: profile.id, role: "member", status: "active", joined_at: new Date().toISOString()
      });
      if (error?.code === "23505") throw new Error("Ce membre possède déjà une adhésion ou une demande.");
      if (error) throw error;
      toast("Membre ajouté au salon.");
      await load();
      await selectSpace(space.id);
    } catch (error) {
      console.error("Salon invite failed:", error);
      toast(error.message || "Impossible d’inviter ce membre.", true);
    } finally {
      button.disabled = false;
    }
  }

  $("#salon-create-form")?.addEventListener("submit", createSalon);
  $("#refresh-salons")?.addEventListener("click", load);
  $("#salon-search")?.addEventListener("input", renderList);
  $("#salon-city-filter")?.addEventListener("change", renderList);
  $("#salon-visibility")?.addEventListener("change", () => {
    const isPrivate = $("#salon-visibility").value === "private";
    const policy = $("#salon-join-policy");
    if (isPrivate && policy.value === "open") policy.value = "invite_only";
    if (!isPrivate && policy.value === "invite_only") policy.value = "open";
    $("#salon-private-note").textContent = isPrivate
      ? "Les salons privés ne sont pas visibles dans la découverte. Le propriétaire peut inviter un membre par nom d’utilisateur."
      : "Les salons publics apparaissent dans la découverte selon leur ville et leurs règles d’accès.";
  });

  window.BaddieLinkSalons = Object.freeze({ load });
  if (window.baddielinkSupabase) load();
  window.addEventListener("pageshow", load);
})();