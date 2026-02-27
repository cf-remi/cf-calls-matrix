// Worker entrypoint ��� all requests are served from static assets.
// The SPA not_found_handling in wrangler.toml handles client-side routing.
export default {
  async fetch(request, env) {
    return env.ASSETS.fetch(request);
  },
};
