/* ============================================================
   Katy Golf League — Supabase client and auth helpers

   Import as a module:
     <script type="module">
       import { supabase, requireAuth, me } from './assets/db.js';
     </script>

   The publishable key below is meant to be public — it ships in
   the browser. Row level security in the database is what
   actually protects the data, not this key. The service_role
   key must never appear in any file here.
   ============================================================ */

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

export const SUPABASE_URL = 'https://iubvgagijqlwiauzcisj.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_lKELOWF8OUx8iStsbZxuWg_1Vj3XmaH';

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

/* ------------------------------------------------------------
   Giphy
   Get a free key at developers.giphy.com — create an account,
   create an app, pick the API option rather than the SDK. The
   key is public by design; it's rate limited, not secret.

   Leave it empty and the GIF buttons simply don't appear.

   Rating is capped at pg-13. Giphy's terms also require their
   attribution mark to be shown wherever results appear, which
   the picker does.
------------------------------------------------------------ */
export const GIPHY_KEY = '';
export const GIPHY_RATING = 'pg-13';

export async function searchGifs(query, limit = 24) {
  if (!GIPHY_KEY) return [];
  const base = query.trim()
    ? `https://api.giphy.com/v1/gifs/search?q=${encodeURIComponent(query)}&`
    : `https://api.giphy.com/v1/gifs/trending?`;
  const url = `${base}api_key=${GIPHY_KEY}&limit=${limit}&rating=${GIPHY_RATING}&bundle=messaging_non_clips`;
  try {
    const r = await fetch(url);
    if (!r.ok) return [];
    const j = await r.json();
    return (j.data || []).map(g => ({
      id: g.id,
      alt: g.title || 'GIF',
      thumb: g.images?.fixed_width_downsampled?.url || g.images?.fixed_width?.url,
      full:  g.images?.downsized_medium?.url || g.images?.original?.url
    })).filter(g => g.thumb && g.full);
  } catch {
    return [];
  }
}

/* ------------------------------------------------------------
   Session
------------------------------------------------------------ */
export async function getSession() {
  const { data } = await supabase.auth.getSession();
  return data.session;
}

/* Send someone to sign in, remembering where they were headed. */
export async function requireAuth(loginPath = 'login.html') {
  const session = await getSession();
  if (!session) {
    const back = encodeURIComponent(location.pathname + location.search);
    location.replace(`${loginPath}?next=${back}`);
    return null;
  }
  return session;
}

/* ------------------------------------------------------------
   Who am I
   Reads the `me` view: profile plus team, in one query.
   Cached for the page so repeated calls are free.
------------------------------------------------------------ */
let _me = null;
export async function me({ fresh = false } = {}) {
  if (_me && !fresh) return _me;
  const { data, error } = await supabase.from('me').select('*').maybeSingle();
  if (error) { console.error('me()', error); return null; }
  _me = data;
  return data;
}

export async function isAdmin() {
  const p = await me();
  return !!(p && p.is_admin);
}

/* ------------------------------------------------------------
   Auth actions
   Each returns { ok, error } so callers can show a message
   rather than dealing with exceptions.
------------------------------------------------------------ */
const wrap = async fn => {
  try {
    const { error } = await fn();
    return error ? { ok:false, error: friendly(error) } : { ok:true };
  } catch (e) {
    return { ok:false, error: friendly(e) };
  }
};

export const signIn = (email, password) =>
  wrap(() => supabase.auth.signInWithPassword({ email: email.trim(), password }));

export const signUp = (email, password, fullName) =>
  wrap(() => supabase.auth.signUp({
    email: email.trim(),
    password,
    options: {
      data: { full_name: fullName?.trim() || null },
      emailRedirectTo: new URL('login.html', location.href).href
    }
  }));

export const sendReset = email =>
  wrap(() => supabase.auth.resetPasswordForEmail(email.trim(), {
    redirectTo: new URL('login.html?mode=reset', location.href).href
  }));

export const setPassword = password =>
  wrap(() => supabase.auth.updateUser({ password }));

export async function signOut() {
  _me = null;
  await supabase.auth.signOut();
}

/* ------------------------------------------------------------
   Roster claiming
------------------------------------------------------------ */
export async function openSpots() {
  const { data, error } = await supabase.from('open_spots').select('*');
  if (error) { console.error('openSpots', error); return []; }
  return data;
}

export async function claimSpot(spotId, code = null) {
  const { error } = await supabase.rpc('claim_spot', {
    p_spot: spotId, p_code: code
  });
  if (error) return { ok:false, error: friendly(error) };
  _me = null;
  return { ok:true };
}

/* ------------------------------------------------------------
   Error messages people can act on
------------------------------------------------------------ */
function friendly(e) {
  const m = (e && e.message ? e.message : String(e)).toLowerCase();
  if (m.includes('invalid login credentials'))  return 'That email and password don\u2019t match.';
  if (m.includes('email not confirmed'))        return 'Check your email and click the confirmation link first.';
  if (m.includes('already registered'))         return 'There\u2019s already an account with that email. Try signing in.';
  if (m.includes('password should be'))         return 'Password needs to be at least 6 characters.';
  if (m.includes('rate limit') || m.includes('too many'))
                                                return 'Too many tries. Wait a minute and go again.';
  if (m.includes('already claimed'))            return 'Someone already claimed that spot. Ask Chris.';
  if (m.includes('already on a team'))          return 'You\u2019re already on a team.';
  if (m.includes('failed to fetch'))            return 'Can\u2019t reach the server. Check your connection.';
  return e && e.message ? e.message : 'Something went wrong.';
}

/* ------------------------------------------------------------
   Drop-in header state: shows the signed-in name and a sign out
   link wherever an element with id="authslot" exists.
------------------------------------------------------------ */
export async function paintAuthSlot(depth = 0) {
  const slot = document.getElementById('authslot');
  if (!slot) return;
  const up = depth ? '../' : '';
  const session = await getSession();

  if (!session) {
    slot.innerHTML = `<a href="${up}login.html">Sign in</a>`;
    return;
  }
  const p = await me();
  const name = p?.full_name || session.user.email;
  slot.innerHTML =
    `<a href="${up}edit-team.html">${name}</a>` +
    (p?.is_admin ? ` <a href="${up}admin.html">Admin</a>` : '') +
    ` <button type="button" id="signout">Sign out</button>`;
  document.getElementById('signout').addEventListener('click', async () => {
    await signOut();
    location.reload();
  });
}
