<script lang="ts">
	import Mark from '$lib/components/Mark.svelte';
	import GithubIcon from '$lib/components/GithubIcon.svelte';
	import { parseEnv, buildEnv } from '$lib/env';
	import { encryptSecret } from '$lib/crypto';
	import { createSecret, fetchStatus, type CreateResult } from '$lib/api';

	let phase = $state<'edit' | 'creating' | 'ready'>('edit');
	let text = $state('');
	let excluded = $state(new Set<string>());
	let ttl = $state(86400);
	let maxViews = $state(1);
	let error = $state('');
	let dragging = $state(false);

	let pairs = $derived(parseEnv(text));
	let included = $derived(pairs.filter((p) => !excluded.has(p.key)));

	let result = $state<CreateResult | null>(null);
	let link = $state('');
	let copied = $state(false);
	let opened = $state(false);

	const ttlOptions = [
		{ label: '1 hour', v: 3600 },
		{ label: '24 hours', v: 86400 },
		{ label: '7 days', v: 604800 }
	];
	const viewOptions = [
		{ label: '1', v: 1 },
		{ label: '5', v: 5 },
		{ label: '∞', v: 0 }
	];

	function toggle(key: string) {
		const next = new Set(excluded);
		next.has(key) ? next.delete(key) : next.add(key);
		excluded = next;
	}

	async function onDrop(e: DragEvent) {
		e.preventDefault();
		dragging = false;
		const file = e.dataTransfer?.files?.[0];
		if (file) text = await file.text();
	}

	async function create() {
		error = '';
		const plaintext = pairs.length ? buildEnv(included) : text.trim();
		if (!plaintext) {
			error = 'Paste an .env first.';
			return;
		}
		phase = 'creating';
		try {
			const sealed = await encryptSecret(plaintext);
			const res = await createSecret({
				ciphertext: sealed.ciphertext,
				iv: sealed.iv,
				ttl,
				maxViews
			});
			result = res;
			link = `${location.origin}/s/${res.id}#${sealed.key}`;
			phase = 'ready';
		} catch (e) {
			error = e instanceof Error ? e.message : 'Something went wrong.';
			phase = 'edit';
		}
	}

	async function copy() {
		await navigator.clipboard.writeText(link);
		copied = true;
		setTimeout(() => (copied = false), 1800);
	}

	function reset() {
		phase = 'edit';
		text = '';
		excluded = new Set();
		result = null;
		link = '';
		opened = false;
		error = '';
	}

	$effect(() => {
		if (phase !== 'ready' || !result || opened) return;
		const { id, notifyToken } = result;
		const t = setInterval(async () => {
			const s = await fetchStatus(id, notifyToken);
			if (s?.opened) {
				opened = true;
				clearInterval(t);
			}
		}, 3000);
		return () => clearInterval(t);
	});

	const ttlLabel = $derived(ttlOptions.find((o) => o.v === ttl)?.label ?? '');
	const viewLabel = $derived(
		maxViews === 0 ? 'unlimited views' : `${maxViews} view${maxViews > 1 ? 's' : ''}`
	);
</script>

<svelte:head>
	<title>Ashdrop — drop it. it turns to ash.</title>
	<meta
		name="description"
		content="Share a .env without handing it over. Encrypted in your browser, shared as one link, gone after a single read."
	/>
</svelte:head>

<header class="nav">
	<a href="/" class="brand"><Mark specks={false} class="brand-mark" />ashdrop</a>
	<nav class="nav-links">
		<a href="/security">security</a>
		<a href="https://github.com/abdullah4tech/ashdrop" target="_blank" rel="noreferrer" class="gh">
			<GithubIcon size="0.95rem" /> GitHub
		</a>
	</nav>
</header>

<main>
	{#if phase !== 'ready'}
		<div class="intro">
			<span class="badge"><span class="badge-dot"></span> zero-knowledge · self-destructing</span>
			<h1>Drop a secret. It turns to ash.</h1>
			<p class="lede">
				Paste your <code>.env</code> — it’s encrypted in your browser, shared as one link, and gone
				after a single read. We never see it.
			</p>
		</div>

		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div
			class="editor"
			class:drag={dragging}
			ondragover={(e) => {
				e.preventDefault();
				dragging = true;
			}}
			ondragleave={() => (dragging = false)}
			ondrop={onDrop}
		>
			<textarea
				bind:value={text}
				spellcheck="false"
				placeholder={'# paste or drop a .env file\nDATABASE_URL=postgres://…\nSTRIPE_KEY=sk_live_…'}
			></textarea>
		</div>

		{#if pairs.length}
			<div class="keys">
				<p class="keys-head">
					{included.length}/{pairs.length} keys included — untick anything you didn’t mean to share
				</p>
				<div class="key-list">
					{#each pairs as p (p.key)}
						<label class="key" class:off={excluded.has(p.key)}>
							<input type="checkbox" checked={!excluded.has(p.key)} onchange={() => toggle(p.key)} />
							<span class="kname">{p.key}</span>
						</label>
					{/each}
				</div>
			</div>
		{/if}

		<div class="options">
			<div class="opt">
				<span class="opt-label">Expires in</span>
				<div class="seg">
					{#each ttlOptions as o (o.v)}
						<button class:active={ttl === o.v} onclick={() => (ttl = o.v)}>{o.label}</button>
					{/each}
				</div>
			</div>
			<div class="opt">
				<span class="opt-label">Max views</span>
				<div class="seg">
					{#each viewOptions as o (o.v)}
						<button class:active={maxViews === o.v} onclick={() => (maxViews = o.v)}>{o.label}</button>
					{/each}
				</div>
			</div>
		</div>

		{#if error}<p class="err">{error}</p>{/if}

		<button class="btn-burn" onclick={create} disabled={phase === 'creating'}>
			{phase === 'creating' ? 'Encrypting…' : 'Encrypt & create link'}
		</button>

		<p class="foot-note">no account · free · open source · <a href="/security">how it’s secured →</a></p>
	{:else}
		<div class="ready">
			<span class="badge">🔒 Encrypted · ready to share</span>
			<h1>Your link is ready</h1>
			<p class="lede">Share only this link. It carries the key in the part servers never see.</p>

			<div class="linkbox">
				<input class="link" readonly value={link} onclick={(e) => e.currentTarget.select()} />
				<button class="copy" onclick={copy}>{copied ? 'Copied ✓' : 'Copy link'}</button>
			</div>

			<div class="meta">
				<span class="chip" class:open={opened}>
					<span class="chip-dot"></span>
					{opened ? 'Opened ✓' : 'Not opened yet'}
				</span>
				<span class="meta-sub">expires in {ttlLabel} · {viewLabel}</span>
			</div>

			<button class="btn-ghost" onclick={reset}>Drop another →</button>
		</div>
	{/if}
</main>

<style>
	.nav {
		display: flex;
		align-items: center;
		justify-content: space-between;
		max-width: 44rem;
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
	.brand :global(.brand-mark) {
		color: var(--color-rust);
	}
	.nav-links {
		display: flex;
		align-items: center;
		gap: 1.4rem;
		font-size: 0.85rem;
	}
	.nav-links a {
		color: var(--color-ash);
		text-decoration: none;
	}
	.nav-links a:hover {
		color: var(--color-ink);
	}
	.nav-links .gh {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		color: var(--color-rust);
	}

	main {
		max-width: 44rem;
		margin: 0 auto;
		padding: 1rem 1.5rem 5rem;
	}
	.intro {
		margin-bottom: 1.6rem;
	}
	.badge {
		display: inline-flex;
		align-items: center;
		gap: 0.45rem;
		font-family: var(--font-mono);
		font-size: 0.72rem;
		color: var(--color-ash);
		border: 1px solid var(--color-ashline);
		border-radius: 999px;
		padding: 0.3rem 0.7rem;
	}
	.badge-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--color-rust);
		animation: pulse 2.4s ease-in-out infinite;
	}
	@keyframes pulse {
		0%,
		100% {
			opacity: 1;
		}
		50% {
			opacity: 0.3;
		}
	}
	h1 {
		font-family: var(--font-display);
		font-size: clamp(1.9rem, 4.4vw, 2.8rem);
		font-weight: 700;
		letter-spacing: -0.03em;
		line-height: 1.05;
		margin: 1rem 0 0.6rem;
	}
	.lede {
		color: color-mix(in oklab, var(--color-ink) 75%, var(--color-bone));
		margin: 0;
		font-size: 1.04rem;
		line-height: 1.55;
		max-width: 36rem;
	}
	code {
		font-family: var(--font-mono);
		color: var(--color-rust);
		font-size: 0.9em;
	}

	.editor {
		border: 1px solid var(--color-ashline);
		border-radius: 12px;
		background: var(--color-paper);
		overflow: hidden;
		transition: border-color 0.2s, box-shadow 0.2s;
	}
	.editor.drag {
		border-color: var(--color-rust);
		box-shadow: 0 0 0 3px color-mix(in oklab, var(--color-rust) 18%, transparent);
	}
	textarea {
		width: 100%;
		min-height: 12rem;
		resize: vertical;
		border: 0;
		outline: none;
		padding: 1.1rem 1.2rem;
		background: transparent;
		color: var(--color-ink);
		font-family: var(--font-mono);
		font-size: 0.88rem;
		line-height: 1.7;
	}
	textarea::placeholder {
		color: color-mix(in oklab, var(--color-ash) 80%, transparent);
	}

	.keys {
		margin-top: 1.2rem;
	}
	.keys-head {
		font-size: 0.8rem;
		color: var(--color-ash);
		margin: 0 0 0.7rem;
	}
	.key-list {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
	.key {
		display: inline-flex;
		align-items: center;
		gap: 0.45rem;
		padding: 0.4rem 0.7rem;
		border: 1px solid var(--color-ashline);
		border-radius: 999px;
		background: var(--color-paper);
		font-family: var(--font-mono);
		font-size: 0.78rem;
		cursor: pointer;
		transition: opacity 0.15s;
	}
	.key.off {
		opacity: 0.4;
	}
	.key input {
		accent-color: var(--color-rust);
	}

	.options {
		display: flex;
		flex-wrap: wrap;
		gap: 1.6rem;
		margin: 1.8rem 0;
	}
	.opt-label {
		display: block;
		font-size: 0.78rem;
		color: var(--color-ash);
		margin-bottom: 0.5rem;
	}
	.seg {
		display: inline-flex;
		border: 1px solid var(--color-ashline);
		border-radius: 9px;
		overflow: hidden;
	}
	.seg button {
		padding: 0.5rem 1rem;
		border: 0;
		background: var(--color-paper);
		color: var(--color-ink);
		font-family: var(--font-mono);
		font-size: 0.82rem;
		cursor: pointer;
		border-right: 1px solid var(--color-ashline);
	}
	.seg button:last-child {
		border-right: 0;
	}
	.seg button.active {
		background: var(--color-rust);
		color: var(--color-paper);
	}

	.err {
		color: #b3402f;
		font-size: 0.88rem;
		margin: 0 0 1rem;
	}

	.btn-burn {
		padding: 0.9rem 1.6rem;
		border: 0;
		border-radius: 10px;
		background: var(--color-rust);
		color: var(--color-paper);
		font-weight: 600;
		font-size: 1rem;
		cursor: pointer;
		transition: background 0.2s, transform 0.18s;
	}
	.btn-burn:hover:not(:disabled) {
		background: var(--color-rust-deep);
		transform: translateY(-2px);
	}
	.btn-burn:disabled {
		opacity: 0.7;
		cursor: progress;
	}

	.foot-note {
		margin-top: 1.4rem;
		font-family: var(--font-mono);
		font-size: 0.76rem;
		color: var(--color-ash);
	}
	.foot-note a {
		color: var(--color-rust);
		text-decoration: none;
	}

	/* ready state */
	.linkbox {
		display: flex;
		gap: 0.6rem;
		margin: 0.4rem 0 1.4rem;
		flex-wrap: wrap;
	}
	.link {
		flex: 1;
		min-width: 14rem;
		padding: 0.8rem 1rem;
		border: 1px solid var(--color-ashline);
		border-radius: 10px;
		background: var(--color-paper);
		font-family: var(--font-mono);
		font-size: 0.82rem;
		color: var(--color-ink);
	}
	.copy {
		padding: 0.8rem 1.3rem;
		border: 0;
		border-radius: 10px;
		background: var(--color-rust);
		color: var(--color-paper);
		font-weight: 600;
		cursor: pointer;
	}
	.copy:hover {
		background: var(--color-rust-deep);
	}
	.meta {
		display: flex;
		align-items: center;
		gap: 1rem;
		flex-wrap: wrap;
		margin-bottom: 1.8rem;
	}
	.chip {
		display: inline-flex;
		align-items: center;
		gap: 0.45rem;
		font-family: var(--font-mono);
		font-size: 0.8rem;
		color: var(--color-ash);
	}
	.chip-dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--color-ash);
	}
	.chip.open {
		color: var(--color-rust);
	}
	.chip.open .chip-dot {
		background: var(--color-rust);
		box-shadow: 0 0 8px 1px color-mix(in oklab, var(--color-rust) 60%, transparent);
	}
	.meta-sub {
		font-size: 0.8rem;
		color: var(--color-ash);
	}
	.btn-ghost {
		padding: 0.7rem 1.2rem;
		border: 1px solid var(--color-rust);
		border-radius: 9px;
		background: transparent;
		color: var(--color-rust);
		font-weight: 600;
		cursor: pointer;
	}
	.btn-ghost:hover {
		background: var(--color-rust);
		color: var(--color-paper);
	}
</style>
