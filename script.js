(() => {
  "use strict";
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const state = { mode: "signup", user: null, likes: [], activeView: "discover" };
  const demoProfiles = [
    {id:1,name:"Aminata",age:26,city:"Abidjan",bio:"Passionnée de musique et de découvertes.",photo:"photo-1"},
    {id:2,name:"Kevin",age:29,city:"Grand-Bassam",bio:"Entre plage, sport et bons moments.",photo:"photo-2"},
    {id:3,name:"Grâce",age:25,city:"Yamoussoukro",bio:"J’aime les voyages et les conversations sincères.",photo:"photo-3"},
    {id:4,name:"Yao",age:28,city:"Bouaké",bio:"Curieux, calme et amateur de cuisine.",photo:"photo-4"},
    {id:5,name:"Mariam",age:27,city:"San-Pédro",bio:"La nature, les livres et les petits plaisirs.",photo:"photo-5"},
    {id:6,name:"Koffi",age:30,city:"Korhogo",bio:"Entrepreneuriat, culture et sport.",photo:"photo-6"}
  ];
  const viewMeta = {
    discover:["VOTRE ESPACE","Découvrir","Des profils à découvrir, près de vous."],
    likes:["VOTRE SÉLECTION","Mes likes","Retrouvez les profils qui ont retenu votre attention."],
    messages:["ÉCHANGER","Messages","Une conversation peut commencer par un simple bonjour."],
    wallet:["VOTRE PORTEFEUILLE","Portefeuille","Les cadeaux et crédits seront disponibles après intégration des paiements."],
    profile:["VOTRE IDENTITÉ","Mon profil","Gérez les informations visibles sur votre profil."],
    settings:["VOS PRÉFÉRENCES","Paramètres","La configuration de votre espace BaddieLink."]
  };
  let toastTimer;
  function toast(message) {
    const el = $("#toast"); if (!el) return;
    el.textContent = message; el.classList.add("show");
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
  }
  function showAgeGate() {
    const modal = $("#age-modal");
    if (!sessionStorage.getItem("baddielink-age-declared")) modal.classList.remove("hidden");
  }
  function closeAgeGate() { sessionStorage.setItem("baddielink-age-declared","1"); $("#age-modal").classList.add("hidden"); }
  function showAuth(mode = "signup") {
    state.mode = mode;
    $("#welcome").classList.add("hidden");
    $("#app-shell").classList.add("hidden");
    $("#auth-panel").classList.remove("hidden");
    const signup = mode === "signup";
    $("#auth-title").textContent = signup ? "Créer votre compte" : "Se connecter";
    $("#auth-subtitle").textContent = signup ? "Quelques informations pour commencer." : "Ravi de vous retrouver sur BaddieLink.";
    $("#name-field").classList.toggle("hidden", !signup);
    $("#terms").required = signup;
    $("#auth-submit").textContent = signup ? "Créer mon compte" : "Se connecter";
    $("#switch-auth").firstChild.textContent = signup ? "Vous avez déjà un compte ? " : "Pas encore de compte ? ";
    $("#switch-auth-button").textContent = signup ? "Se connecter" : "Créer un compte";
    $("#password").autocomplete = signup ? "new-password" : "current-password";
    location.hash = signup ? "inscription" : "connexion";
  }
  function enterApp(name) {
    state.user = {name: name || "Membre BaddieLink"};
    $("#auth-panel").classList.add("hidden"); $("#welcome").classList.add("hidden");
    $("#app-shell").classList.remove("hidden");
    $("#sidebar-name").textContent = state.user.name;
    $("#profile-name").textContent = state.user.name;
    $(".avatar-user").textContent = state.user.name.trim().charAt(0).toUpperCase() || "B";
    showView("discover"); renderProfiles(); location.hash = "espace";
  }
  function showView(view) {
    if (!viewMeta[view]) return;
    state.activeView = view;
    $$(".view").forEach(el => el.classList.toggle("active", el.id === "view-" + view));
    $$(".nav-item[data-view]").forEach(el => el.classList.toggle("active", el.dataset.view === view));
    const [kicker,title,description] = viewMeta[view];
    $("#view-kicker").textContent = kicker; $("#view-title").textContent = title; $("#view-description").textContent = description;
    if (view === "likes") renderLikes();
  }
  function profileCard(profile) {
    const liked = state.likes.includes(profile.id);
    return `<article class="person-card"><div class="person-photo ${profile.photo}"><span class="demo-badge">Profil fictif</span></div><div class="person-info"><h3>${profile.name}, ${profile.age}</h3><p>⌖ ${profile.city} · Côte d’Ivoire</p><p>${profile.bio}</p><div class="person-actions"><button class="like-button" data-like="${profile.id}">${liked ? "♥ Aimé" : "♡ J’aime"}</button><button data-message="${profile.name}">Message</button></div></div></article>`;
  }
  function renderProfiles() {
    const city = $("#city-filter").value;
    const profiles = demoProfiles.filter(p => city === "Toutes les villes" || p.city === city);
    $("#profile-grid").innerHTML = profiles.map(profileCard).join("");
    $("#likes-count").textContent = state.likes.length;
  }
  function renderLikes() {
    const liked = demoProfiles.filter(p => state.likes.includes(p.id));
    $("#likes-grid").innerHTML = liked.map(profileCard).join("");
    $(".empty-state").classList.toggle("hidden", liked.length > 0);
    $("#likes-count").textContent = state.likes.length;
  }
  function handleProfileAction(event) {
    const likeButton = event.target.closest("[data-like]");
    if (likeButton) {
      const id = Number(likeButton.dataset.like);
      state.likes = state.likes.includes(id) ? state.likes.filter(x => x !== id) : [...state.likes,id];
      renderProfiles(); renderLikes(); return;
    }
    const messageButton = event.target.closest("[data-message]");
    if (messageButton) { showView("messages"); toast("Conversation de démonstration ouverte."); }
  }
  $("#header-login").addEventListener("click", () => showAuth("login"));
  $("#hero-login").addEventListener("click", () => showAuth("login"));
  $("#header-signup").addEventListener("click", () => showAuth("signup"));
  $("#hero-signup").addEventListener("click", () => showAuth("signup"));
  $("#back-home").addEventListener("click", () => { $("#auth-panel").classList.add("hidden"); $("#welcome").classList.remove("hidden"); location.hash = ""; });
  $("#switch-auth-button").addEventListener("click", () => showAuth(state.mode === "signup" ? "login" : "signup"));
  $("#auth-form").addEventListener("submit", event => {
    event.preventDefault();
    const email = $("#email").value.trim();
    const password = $("#password").value;
    const name = $("#full-name").value.trim();
    const phone = $("#phone").value.replace(/\D/g,"");
    if (state.mode === "signup" && !name) { toast("Veuillez saisir un nom affiché."); return; }
    if (password.length < 8) { toast("Le mot de passe doit contenir au moins 8 caractères."); return; }
    if (phone && phone.length !== 10) { toast("Le numéro ivoirien doit contenir 10 chiffres après +225."); return; }
    if (!email.includes("@")) { toast("Veuillez vérifier votre adresse e-mail."); return; }
    toast(state.mode === "signup" ? "Mode démo : aucun compte serveur n’a été créé." : "Mode démo : aucune authentification serveur n’est active.");
    enterApp(name || email.split("@")[0]);
  });
  $$(".nav-item[data-view]").forEach(button => button.addEventListener("click", () => showView(button.dataset.view)));
  $("#logout").addEventListener("click", () => { state.user = null; $("#app-shell").classList.add("hidden"); $("#welcome").classList.remove("hidden"); location.hash = ""; });
  $("#city-filter").addEventListener("change", renderProfiles);
  $("#profile-grid").addEventListener("click", handleProfileAction);
  $("#likes-grid").addEventListener("click", handleProfileAction);
  $$("[data-goto]").forEach(button => button.addEventListener("click", () => showView(button.dataset.goto)));
  $("#chat-form").addEventListener("submit", event => {
    event.preventDefault();
    const input = $("#chat-message"), value = input.value.trim();
    if (!value) return;
    const bubble = document.createElement("div"); bubble.className = "bubble sent"; bubble.textContent = value;
    $("#chat-body").append(bubble); input.value = ""; $("#chat-body").scrollTop = $("#chat-body").scrollHeight;
    toast("Message ajouté localement. Il n’a pas été envoyé.");
  });
  $("#age-confirm").addEventListener("click", closeAgeGate);
  $("#age-decline").addEventListener("click", () => { $("#age-modal").classList.add("hidden"); $("#welcome").classList.add("hidden"); toast("L’accès est réservé aux personnes majeures."); });
  $("#mobile-settings").addEventListener("click", () => showView("settings"));
  $("#edit-profile").addEventListener("click", () => toast("L’édition du profil sera activée avec le backend."));
  if (location.hash === "#inscription") showAuth("signup");
  else if (location.hash === "#connexion") showAuth("login");
  else showAgeGate();
})();