<script lang="ts">
	import '../app.css';
	import favicon from '$lib/assets/favicon.svg';
	import Github from '$lib/components/Github.svelte';
	import { page } from '$app/state';

	let { children } = $props();

	const is = (path: string) => page.url.pathname === path;
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<header class="nav">
	<div class="nav-inner">
		<a href="/" class="brand"><span class="brand-ash">ash</span>drop</a>
		<nav class="nav-links">
			<a href="/security" aria-current={is('/security') ? 'page' : undefined}>security</a>
			<a
				href="https://github.com/abdullah4tech/ashdrop"
				target="_blank"
				rel="noreferrer"
				class="gh-link"
			>
				<Github size="0.9rem" />GitHub
			</a>
		</nav>
	</div>
</header>

{@render children()}

<style>
	.nav {
		padding: 0 1.5rem;
	}
	.nav-inner {
		max-width: 72rem;
		margin: 0 auto;
		height: 4.75rem;
		display: flex;
		align-items: center;
		justify-content: space-between;
	}
	.brand {
		font-family: var(--font-mono);
		font-weight: 700;
		font-size: 1.4rem;
		color: var(--color-ink);
		text-decoration: none;
		letter-spacing: -0.02em;
	}
	.nav-links {
		display: flex;
		align-items: center;
		gap: 1.9rem;
		font-size: 0.92rem;
	}
	.nav-links a {
		color: var(--color-muted);
		text-decoration: none;
		transition: color 0.12s;
	}
	.nav-links a:hover,
	.nav-links a[aria-current='page'] { color: var(--color-ink); }
</style>
