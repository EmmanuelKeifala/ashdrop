<script lang="ts">
	import { inview } from '$lib/actions/inview';
	import Mark from '$lib/components/Mark.svelte';
	import GithubIcon from '$lib/components/GithubIcon.svelte';

	const mitigated = [
		{ threat: 'Database or server breach', how: 'Only ciphertext is stored. The key is never sent, so a full dump is noise.' },
		{ threat: 'Network sniffing', how: 'TLS in transit, and the key rides in the URL fragment — never transmitted.' },
		{ threat: 'Replay / re-reading a link', how: 'View-once burn plus a TTL the datastore enforces itself.' },
		{ threat: 'A rogue operator', how: 'Zero-knowledge means even we can’t read your secret. There’s nothing to hand over.' }
	];

	const edges = [
		{ threat: 'A compromised device', how: 'If the sender’s or receiver’s machine is already owned, no web app can save the plaintext once it’s decrypted there.' },
		{ threat: 'Trusting the served JavaScript', how: 'You’re trusting that the code we serve is the honest code. That’s true of every end-to-end web app. Mitigations: strict CSP, no third-party scripts on crypto pages, and an open repo you can audit or self-host.' },
		{ threat: 'A leaked link', how: 'Anyone with the full link can open the secret once. Add a passphrase (shared over a separate channel) for links sent somewhere risky.' }
	];
</script>

<svelte:head>
	<title>Security — Ashdrop</title>
	<meta name="description" content="How Ashdrop’s zero-knowledge model works, what it protects, and exactly where the edges are." />
</svelte:head>

<header class="nav">
	<a href="/" class="brand"><Mark specks={false} class="brand-mark" />ashdrop</a>
	<nav class="nav-links">
		<a href="/#how">how it works</a>
		<a href="/security" aria-current="page">security</a>
		<a href="https://github.com/abdullah4tech/ashdrop" target="_blank" rel="noreferrer" class="gh">
			<GithubIcon size="0.95rem" /> GitHub
		</a>
	</nav>
</header>

<main>
	<section class="head">
		<p class="eyebrow">security</p>
		<h1>The server can’t read your secrets. Here’s how — and where the edges are.</h1>
		<p class="lede">
			Everything is encrypted and decrypted in your browser with AES-256-GCM. The server is a dumb
			vault: it holds ciphertext for a little while and counts views. It has no key and no way to
			read a secret — by design, not by policy.
		</p>
		<a href="https://github.com/abdullah4tech/ashdrop" target="_blank" rel="noreferrer" class="btn-ghost">Read the code →</a>
	</section>

	<section class="band" use:inview>
		<h2>The flow</h2>
		<ol class="flow">
			<li><span class="num">01</span> A random 256-bit key and nonce are generated in your browser.</li>
			<li><span class="num">02</span> Your <code>.env</code> is encrypted locally. Only ciphertext is sent to us.</li>
			<li><span class="num">03</span> The key is placed in the link’s <code>#fragment</code> — which browsers never send to any server.</li>
			<li><span class="num">04</span> The recipient’s browser reads the key from the fragment and decrypts locally.</li>
			<li><span class="num">05</span> On open, the secret is burned: the stored ciphertext is deleted.</li>
		</ol>
	</section>

	<section class="band" use:inview>
		<h2>What this protects</h2>
		<div class="rows">
			{#each mitigated as m (m.threat)}
				<div class="row good">
					<span class="tag">✓ covered</span>
					<div>
						<h3>{m.threat}</h3>
						<p>{m.how}</p>
					</div>
				</div>
			{/each}
		</div>
	</section>

	<section class="band" use:inview>
		<h2>Where the edges are</h2>
		<p class="prose">
			We’d rather tell you the limits than overclaim. These gaps are inherent to every end-to-end web
			app — pretending otherwise would be the real security flaw.
		</p>
		<div class="rows">
			{#each edges as e (e.threat)}
				<div class="row edge">
					<span class="tag">△ your call</span>
					<div>
						<h3>{e.threat}</h3>
						<p>{e.how}</p>
					</div>
				</div>
			{/each}
		</div>
	</section>

	<section class="band cta" use:inview>
		<h2>Don’t take our word for it</h2>
		<p class="prose">The code is open. Audit it, file an issue, or run your own copy.</p>
		<div class="cta-row">
			<a href="https://github.com/abdullah4tech/ashdrop" target="_blank" rel="noreferrer" class="btn-burn">Read the code</a>
			<a href="/" class="btn-ghost">Drop a secret →</a>
		</div>
	</section>

	<footer class="foot">
		<div class="foot-brand"><Mark specks={false} class="brand-mark" />ashdrop</div>
		<p class="foot-tag">drop it. it turns to ash.</p>
	</footer>
</main>

<style>
	.nav {
		display: flex;
		align-items: center;
		justify-content: space-between;
		max-width: 76rem;
		margin: 0 auto;
		padding: 1.5rem;
	}
	.brand {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		font-family: var(--font-mono);
		font-weight: 700;
		font-size: 1.05rem;
		color: var(--color-ink);
		text-decoration: none;
	}
	.brand :global(.brand-mark),
	.foot-brand :global(.brand-mark) {
		color: var(--color-rust);
	}
	.nav-links {
		display: flex;
		gap: 1.6rem;
		font-size: 0.85rem;
	}
	.nav-links a {
		color: var(--color-ash);
		text-decoration: none;
	}
	.nav-links a[aria-current='page'] {
		color: var(--color-ink);
	}
	.nav-links .gh {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		color: var(--color-rust);
	}

	main {
		max-width: 50rem;
		margin: 0 auto;
		padding: 0 1.5rem;
	}
	.eyebrow {
		font-family: var(--font-mono);
		font-size: 0.74rem;
		letter-spacing: 0.14em;
		text-transform: uppercase;
		color: var(--color-rust);
		margin: 0 0 1rem;
	}
	.head {
		padding: 2.5rem 0 1rem;
	}
	.head h1 {
		font-family: var(--font-display);
		font-weight: 700;
		font-size: clamp(1.9rem, 4.5vw, 3rem);
		line-height: 1.1;
		letter-spacing: -0.03em;
		margin: 0 0 1.3rem;
		max-width: 30ch;
	}
	.lede {
		font-size: 1.1rem;
		line-height: 1.6;
		color: color-mix(in oklab, var(--color-ink) 80%, var(--color-bone));
		max-width: 48ch;
		margin: 0 0 1.6rem;
	}

	.band {
		padding: 2.8rem 0;
		border-top: 1px solid var(--color-ashline);
		opacity: 0;
		transform: translateY(14px);
		transition: opacity 0.6s ease, transform 0.6s ease;
	}
	.band:global([data-inview='true']) {
		opacity: 1;
		transform: none;
	}
	.band h2 {
		font-family: var(--font-display);
		font-size: 1.5rem;
		margin: 0 0 1.4rem;
		letter-spacing: -0.02em;
	}
	.prose {
		font-size: 1.02rem;
		line-height: 1.65;
		color: color-mix(in oklab, var(--color-ink) 76%, var(--color-bone));
		max-width: 56ch;
		margin: 0 0 1.6rem;
	}
	code {
		font-family: var(--font-mono);
		font-size: 0.88em;
		color: var(--color-rust);
	}

	.flow {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 0.9rem;
	}
	.flow li {
		display: flex;
		align-items: baseline;
		gap: 0.9rem;
		font-size: 1rem;
		line-height: 1.55;
	}
	.num {
		font-family: var(--font-mono);
		font-size: 0.8rem;
		color: var(--color-rust);
		flex-shrink: 0;
	}

	.rows {
		display: flex;
		flex-direction: column;
		gap: 0.9rem;
	}
	.row {
		display: flex;
		gap: 1rem;
		padding: 1.1rem 1.2rem;
		border: 1px solid var(--color-ashline);
		border-radius: 12px;
		background: var(--color-paper);
	}
	.row.edge {
		background: color-mix(in oklab, var(--color-rust) 5%, var(--color-paper));
		border-color: color-mix(in oklab, var(--color-rust) 25%, var(--color-ashline));
	}
	.tag {
		font-family: var(--font-mono);
		font-size: 0.68rem;
		white-space: nowrap;
		flex-shrink: 0;
		padding-top: 0.2rem;
	}
	.row.good .tag {
		color: #4a7c59;
	}
	.row.edge .tag {
		color: var(--color-rust);
	}
	.row h3 {
		font-family: var(--font-display);
		font-size: 1.05rem;
		margin: 0 0 0.3rem;
	}
	.row p {
		font-size: 0.94rem;
		line-height: 1.5;
		color: color-mix(in oklab, var(--color-ink) 72%, var(--color-bone));
		margin: 0;
	}

	.cta-row {
		display: flex;
		gap: 1rem;
		flex-wrap: wrap;
		align-items: center;
	}
	.btn-burn {
		display: inline-block;
		padding: 0.8rem 1.4rem;
		border-radius: 10px;
		background: var(--color-rust);
		color: var(--color-paper);
		font-weight: 600;
		text-decoration: none;
		transition: background 0.2s, transform 0.18s;
	}
	.btn-burn:hover {
		background: var(--color-rust-deep);
		transform: translateY(-2px);
	}
	.btn-ghost {
		display: inline-block;
		padding: 0.75rem 1.2rem;
		border: 1px solid var(--color-rust);
		border-radius: 9px;
		color: var(--color-rust);
		font-weight: 600;
		text-decoration: none;
		transition: background 0.2s, color 0.2s;
	}
	.btn-ghost:hover {
		background: var(--color-rust);
		color: var(--color-paper);
	}

	.foot {
		padding: 3rem 0 4rem;
		border-top: 1px solid var(--color-ashline);
	}
	.foot-brand {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		font-family: var(--font-mono);
		font-weight: 700;
	}
	.foot-tag {
		color: var(--color-ash);
		font-size: 0.9rem;
		margin: 0.4rem 0 0;
	}
</style>
