<script lang="ts">
	import ArrowRight from '$lib/components/ArrowRight.svelte';
	import EnvBeam from '$lib/components/EnvBeam.svelte';
	import ShareSafe from '$lib/components/ShareSafe.svelte';
	import { reveal } from '$lib/actions/reveal';

	const steps = [
		'Generate your receive address — once, right here.',
		"Share your receive link anywhere — it's a public key, not a secret.",
		'They open it and drop an .env — encrypted in their browser.',
		'Only your browser can decrypt it. The drop turns to ash after one read.'
	];
</script>

<svelte:head>
	<title>Ashdrop — receive a secret. it turns to ash.</title>
	<meta
		name="description"
		content="Get a receive link. People drop an .env into it — encrypted in their browser, readable only in yours, gone after a single read. Zero-knowledge, open source."
	/>
</svelte:head>

<main>
	<!-- 1 · Hero -->
	<section class="hero">
		<p class="eyebrow">end-to-end encrypted · zero-knowledge · open source</p>
		<h1>Receive a secret.<br />Read it once.</h1>
		<p class="sub">
			Share one link. People send you an <code>.env</code> — encrypted in their browser, readable
			only in yours, and gone after a single read. We never see it.
		</p>
		<a class="cta" href="/me">
			Receive a secret
			<span class="btn-icon"><ArrowRight size="0.9rem" /></span>
		</a>
	</section>

	<!-- 2 · How it works -->
	<section class="block">
		<p class="section-head">How it works</p>
		<ol class="steps" use:reveal>
			{#each steps as step, i (i)}
				<li class="step" use:reveal style="--i: {i}">
					<span class="n">{i + 1}</span>
					<span class="step-text">{step}</span>
				</li>
			{/each}
		</ol>
	</section>

	<!-- 3 · Env beam -->
	<section class="block">
		<p class="section-head">The path a secret takes</p>
		<div class="beam-reveal" use:reveal>
			<EnvBeam />
		</div>
		<p class="beam-note">
			Your app's secrets stay encrypted end to end — Ashdrop only ever relays ciphertext to the
			recipient.
		</p>
	</section>

	<!-- 4 · Safe to share over any channel -->
	<section class="block">
		<p class="section-head">Safe to send over WhatsApp</p>
		<div class="share-reveal" use:reveal>
			<ShareSafe />
		</div>
		<p class="beam-note">
			Paste the link into WhatsApp, Slack, or email — it carries no key. The chat app, and anyone
			who intercepts the message, only ever sees a reference to ciphertext. Only the recipient's
			browser holds the key to open it, so even a compromised chat can't leak the secret.
		</p>
	</section>
</main>

<style>
	main {
		max-width: 72rem;
		margin: 0 auto;
		padding: 0 clamp(1.5rem, 5vw, 3rem) 7rem;
	}

	/* ── Hero ── */
	.hero {
		min-height: calc(100svh - 4.75rem);
		display: flex;
		flex-direction: column;
		justify-content: center;
		margin-bottom: 2rem;
	}
	.eyebrow {
		font-family: var(--font-mono);
		font-size: 0.68rem;
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--color-muted);
		margin: 0 0 1rem;
	}
	h1 {
		font-family: var(--font-display);
		font-size: clamp(3rem, 7.5vw, 6rem);
		font-weight: 800;
		letter-spacing: -0.04em;
		line-height: 0.98;
		margin: 0 0 1.4rem;
		color: var(--color-ink);
	}
	.sub {
		font-size: clamp(1rem, 1.4vw, 1.15rem);
		color: var(--color-muted);
		margin: 0 0 2.4rem;
		line-height: 1.6;
		max-width: 40rem;
	}
	code {
		font-family: var(--font-mono);
		font-size: 0.9em;
		color: var(--color-ink);
	}

	.cta {
		display: inline-flex;
		align-items: center;
		gap: 0;
		align-self: flex-start;
		padding: 1.1rem 1.8rem;
		background: var(--color-ink);
		color: var(--color-bg);
		font-family: var(--font-display);
		font-weight: 700;
		font-size: 1.05rem;
		letter-spacing: -0.01em;
		text-decoration: none;
		transition: background 0.12s;
	}
	.cta:hover { background: var(--color-rust); }

	/* ── Section shell ── */
	.block { margin-bottom: 6rem; }
	.section-head {
		font-family: var(--font-mono);
		font-size: 0.72rem;
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--color-muted);
		margin: 0 0 2rem;
	}

	/* ── Steps (vertical draw-in flow) ── */
	.steps {
		position: relative;
		list-style: none;
		margin: 0;
		padding: 0 0 0 0.9rem;
	}
	.steps::before {
		content: '';
		position: absolute;
		left: 0;
		top: 0.6rem;
		bottom: 0.6rem;
		width: 1px;
		background: var(--color-line);
		transform: scaleY(0);
		transform-origin: top;
		transition: transform 0.7s ease;
	}
	.steps:global(.in)::before { transform: scaleY(1); }

	.step {
		display: flex;
		align-items: baseline;
		gap: 1.1rem;
		padding: 1rem 0 1rem 1.6rem;
		font-size: 1.1rem;
		line-height: 1.5;
		color: var(--color-ink);
		opacity: 0;
		transform: translateY(8px);
		transition: opacity 0.5s ease, transform 0.5s ease;
		transition-delay: calc(var(--i) * 0.12s + 0.15s);
	}
	.step:global(.in) {
		opacity: 1;
		transform: translateY(0);
	}
	.n {
		font-family: var(--font-mono);
		font-size: 0.7rem;
		font-weight: 700;
		color: var(--color-rust);
		flex-shrink: 0;
		width: 1.2rem;
	}
	.step-text { max-width: 34rem; }

	/* ── Beam ── */
	.beam-reveal {
		opacity: 0;
		transition: opacity 0.6s ease;
	}
	.beam-reveal:global(.in) { opacity: 1; }

	.share-reveal {
		opacity: 0;
		transition: opacity 0.6s ease;
	}
	.share-reveal:global(.in) { opacity: 1; }

	.beam-note {
		max-width: 30rem;
		margin: 1.4rem auto 0;
		text-align: center;
		font-size: 0.82rem;
		line-height: 1.6;
		color: var(--color-muted);
	}
</style>
