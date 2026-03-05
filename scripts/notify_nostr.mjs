#!/usr/bin/env node
import { finalizeEvent, getPublicKey, nip19, SimplePool } from 'nostr-tools'

function requireEnv(name) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`Missing required env: ${name}`)
  }
  return value
}

function parseSecretKeyBytes(input) {
  if (input.startsWith('nsec1')) {
    const decoded = nip19.decode(input)
    if (decoded.type !== 'nsec' || !(decoded.data instanceof Uint8Array)) {
      throw new Error('NOSTR_NOTIFY_NSEC is not a valid nsec key')
    }
    return decoded.data
  }

  const hex = input.trim().toLowerCase()
  if (!/^[0-9a-f]{64}$/.test(hex)) {
    throw new Error('NOSTR_NOTIFY_NSEC must be nsec1... or 64-char hex secret key')
  }

  return Uint8Array.from(Buffer.from(hex, 'hex'))
}

function splitList(value) {
  return (value || '')
    .split(',')
    .map(v => v.trim())
    .filter(Boolean)
}

function isSuccessfulPublishResult(result) {
  if (typeof result !== 'string') {
    return true
  }
  return !result.startsWith('connection failure:')
}

async function main() {
  const skRaw = requireEnv('NOSTR_NOTIFY_NSEC')
  const relaysRaw = requireEnv('NOSTR_NOTIFY_RELAYS')
  const content = requireEnv('NOSTR_NOTIFY_CONTENT')

  const relayUrls = splitList(relaysRaw)
  if (relayUrls.length === 0) {
    throw new Error('NOSTR_NOTIFY_RELAYS is empty after parsing')
  }

  const extraTagsRaw = process.env.NOSTR_NOTIFY_TAGS || ''
  const extraTags = splitList(extraTagsRaw).map(tag => ['t', tag])

  const sk = parseSecretKeyBytes(skRaw)
  const pubkey = getPublicKey(sk)

  const event = finalizeEvent(
    {
      kind: 1,
      created_at: Math.floor(Date.now() / 1000),
      tags: [['client', 'bilbil-cicd'], ...extraTags],
      content,
    },
    sk,
  )

  const pool = new SimplePool()
  const publishPromises = pool.publish(relayUrls, event)
  const settled = await Promise.allSettled(publishPromises)

  const ok = settled.filter(r => {
    if (r.status !== 'fulfilled') {
      return false
    }
    return isSuccessfulPublishResult(r.value)
  }).length
  const failed = settled.length - ok

  console.log(`nostr notify pubkey: ${pubkey}`)
  console.log(`nostr notify relays total=${settled.length} ok=${ok} failed=${failed}`)

  if (ok === 0) {
    throw new Error('Notification failed on all relays')
  }

  pool.close(relayUrls)
}

main().catch(err => {
  console.error(err instanceof Error ? err.message : String(err))
  process.exit(1)
})
