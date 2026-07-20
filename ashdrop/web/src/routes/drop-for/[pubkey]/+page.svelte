<script lang="ts">
	import { page } from '$app/state';
	import { parseEnv, buildEnv } from '$lib/env';
	import ArrowRight from '$lib/components/ArrowRight.svelte';
	import { encryptForRecipient } from '$lib/crypto';
	import { createSecret, fetchStatus, type CreateResult } from '$lib/api';

	const recipientPubB64 = page.params.pubkey ?? '';

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
	let dropLink = $state('');
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
		if (!plaintext) { error = 'Paste an .env first.'; return; }
		if (!recipientPubB64) { error = 'Invalid receive address.'; return; }
		phase = 'creating';
		try {
			const sealed = await encryptForRecipient(plaintext, recipientPubB64);
			const res = await createSecret({
				ciphertext: sealed.ciphertext,
				iv: sealed.iv,
				ttl,
				maxViews,
				ephemeralPub: sealed.ephemeralPub,
				recipientPub: recipientPubB64
			});
			result = res;
			dropLink = `${location.origin}/s/${res.id}`;
			phase = 'ready';
		} catch (e) {
			error = e instanceof Error ? e.message : 'Something went wrong.';
			phase = 'edit';
		}
	}

	async function copy() {
		await navigator.clipboard.writeText(dropLink);
		copied = true;
		setTimeout(() => (copied = false), 1800);
	}

	function reset() {
		phase = 'edit';
		text = '';
		excluded = new Set();
		result = null;
		dropLink = '';
		opened = false;
		error = '';
	}

	$effect(() => {
		if (phase !== 'ready' || !result || opened) return;
		const { id, notifyToken } = result;
		const t = setInterval(async () => {
			const s = await fetchStatus(id, notifyToken);
			if (s?.opened) { opened = true; clearInterval(t); }
		}, 3000);
		return () => clearInterval(t);
	});

	const ttlLabel = $derived(ttlOptions.find((o) => o.v === ttl)?.label ?? '');
	const viewLabel = $derived(
		maxViews === 0 ? 'unlimited views' : `${maxViews} view${maxViews > 1 ? 's' : ''}`
	);
</script>

<svelte:head>
	<title>Drop a secret — Ashdrop</title>
	<meta name="description" content="Send an encrypted secret that only the recipient can open." />
</svelte:head>

<main>
	{#if phase !== 'ready'}
		<div class="hero">
			<p class="eyebrow">end-to-end encrypted · one recipient only</p>
			<h1>Drop a secret<br />directly.</h1>
			<p class="sub">Only the person who shared this link can open what you drop here. Not the server. Not anyone else.</p>
		</div>

		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div
			class="editor"
			class:drag={dragging}
			ondragover={(e) => { e.preventDefault(); dragging = true; }}
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
				<p class="keys-head">{included.length}/{pairs.length} keys — untick anything you didn't mean to share</p>
				<div class="key-list">
					{#each pairs as p (p.key)}
						<label class="key" class:off={excluded.has(p.key)}>
							<input type="checkbox" checked={!excluded.has(p.key)} onchange={() => toggle(p.key)} />
							<span>{p.key}</span>
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

		<button class="cta" onclick={create} disabled={phase === 'creating'}>
			{phase === 'creating' ? 'Encrypting…' : 'Encrypt & create link'}
			<span class="btn-icon"><ArrowRight size="0.9rem" /></span>
		</button>
	{:else}
		<div class="hero">
			<p class="eyebrow">encrypted · recipient-only</p>
			<h1>Your link<br />is ready.</h1>
			<p class="sub">Share it anywhere — only the recipient's browser can decrypt it. No key in the URL.</p>
		</div>

		<div class="linkrow">
			<input class="linkinput" readonly value={dropLink} onclick={(e) => e.currentTarget.select()} />
			<button class="cta-sm" onclick={copy}>{copied ? 'Copied' : 'Copy link'}</button>
		</div>

		<div class="status-row">
			<span class="dot" class:active={opened}></span>
			<span>{opened ? 'Opened' : 'Not opened yet'}</span>
			<span class="sep">·</span>
			<span>expires {ttlLabel}</span>
			<span class="sep">·</span>
			<span>{viewLabel}</span>
		</div>

		<button class="ghost" onclick={reset}>Drop another →</button>
	{/if}
</main>

<style>
	main {
		max-width: 44rem;
		margin: 0 auto;
		padding: 3.5rem 1.5rem 6rem;
	}

	.hero { margin-bottom: 2.4rem; }
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
		font-size: clamp(2.6rem, 6vw, 4rem);
		font-weight: 800;
		letter-spacing: -0.04em;
		line-height: 1.0;
		margin: 0 0 0.9rem;
	}
	.sub {
		font-size: 0.96rem;
		color: var(--color-muted);
		margin: 0;
		line-height: 1.6;
		max-width: 34rem;
	}

	.editor {
		border: 1px solid var(--color-line);
		background: var(--color-surf);
		transition: border-color 0.15s;
	}
	.editor.drag { border-color: var(--color-rust); }
	textarea {
		width: 100%;
		min-height: 11rem;
		resize: vertical;
		border: 0;
		outline: none;
		padding: 1rem 1.1rem;
		background: transparent;
		color: var(--color-ink);
		font-family: var(--font-mono);
		font-size: 0.85rem;
		line-height: 1.7;
	}
	textarea::placeholder { color: var(--color-line); }

	.keys { margin-top: 1rem; }
	.keys-head { font-size: 0.72rem; color: var(--color-muted); margin: 0 0 0.6rem; font-family: var(--font-mono); }
	.key-list { display: flex; flex-wrap: wrap; gap: 0.4rem; }
	.key {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		padding: 0.3rem 0.65rem;
		border: 1px solid var(--color-line);
		background: var(--color-bg);
		font-family: var(--font-mono);
		font-size: 0.75rem;
		cursor: pointer;
		transition: opacity 0.12s;
		color: var(--color-ink);
	}
	.key.off { opacity: 0.35; }
	.key input { accent-color: var(--color-rust); }

	.options { display: flex; flex-wrap: wrap; gap: 1.8rem; margin: 1.5rem 0; }
	.opt-label {
		display: block;
		font-size: 0.68rem;
		letter-spacing: 0.08em;
		text-transform: uppercase;
		color: var(--color-muted);
		margin-bottom: 0.5rem;
		font-family: var(--font-mono);
	}
	.seg { display: inline-flex; border: 1px solid var(--color-line); }
	.seg button {
		padding: 0.45rem 1rem;
		border: 0;
		border-right: 1px solid var(--color-line);
		background: var(--color-bg);
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 0.8rem;
		cursor: pointer;
		transition: background 0.1s, color 0.1s;
	}
	.seg button:last-child { border-right: 0; }
	.seg button.active { background: var(--color-ink); color: var(--color-bg); }

	.err { color: #c0392b; font-size: 0.82rem; margin: 0 0 1rem; font-family: var(--font-mono); }

	.cta {
		display: flex;
		align-items: center;
		gap: 0;
		width: 100%;
		padding: 0.95rem 1.2rem;
		border: 0;
		background: var(--color-ink);
		color: var(--color-bg);
		font-family: var(--font-display);
		font-weight: 700;
		font-size: 0.95rem;
		letter-spacing: -0.01em;
		cursor: pointer;
		transition: background 0.12s;
	}
	.cta:hover:not(:disabled) { background: var(--color-rust); }
	.cta:disabled { opacity: 0.5; cursor: progress; }

	.linkrow { display: flex; border: 1px solid var(--color-line); margin-bottom: 1.2rem; }
	.linkinput {
		flex: 1;
		min-width: 0;
		padding: 0.8rem 1rem;
		border: 0;
		outline: none;
		background: var(--color-surf);
		font-family: var(--font-mono);
		font-size: 0.8rem;
		color: var(--color-ink);
	}
	.cta-sm {
		padding: 0.8rem 1.2rem;
		border: 0;
		border-left: 1px solid var(--color-line);
		background: var(--color-ink);
		color: var(--color-bg);
		font-family: var(--font-mono);
		font-size: 0.8rem;
		font-weight: 600;
		cursor: pointer;
		white-space: nowrap;
		transition: background 0.12s;
	}
	.cta-sm:hover { background: var(--color-rust); }

	.status-row {
		display: flex;
		align-items: center;
		gap: 0.6rem;
		margin-bottom: 2rem;
		font-family: var(--font-mono);
		font-size: 0.75rem;
		color: var(--color-muted);
	}
	.dot { width: 5px; height: 5px; background: var(--color-line); flex-shrink: 0; }
	.dot.active { background: var(--color-rust); }
	.sep { color: var(--color-line); }

	.ghost {
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-muted);
		font-size: 0.85rem;
		cursor: pointer;
		text-decoration: underline;
		text-underline-offset: 3px;
	}
	.ghost:hover { color: var(--color-ink); }
</style>
