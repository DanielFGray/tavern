const { test, expect } = require('@playwright/test')
const { baseURL, owner, command, login } = require('./support')

// A bot asks the seed owner through the bot API, as barkeep does, and the owner answers on the
// card. An ask stays in the transcript with its answer; a permission request leaves it.
async function sendPrompt(request, question) {
  const { user } = await command(request, 'upsert_user', owner)
  const { channels } = await command(request, 'list_channels')
  const general = channels.find((channel) => channel.slug === 'general')
  const { token } = await command(request, 'create_bot_with_token', { label: 'e2e prompts' })

  const response = await request.post(new URL(`/api/v1/channels/${general.id}/questions`, baseURL).toString(), {
    headers: { Authorization: `Bearer ${token}` },
    data: { question: { ...question, answerer_user_ids: [user.id] } },
  })
  expect(response.status()).toBe(201)
  return (await response.json()).data
}

test('a bot ask shows no poll counts, and its answer stays with the answerer named', async ({ page, request }) => {
  const text = `Deploy to **staging** ${Date.now()}?`
  const message = await sendPrompt(request, {
    kind: 'ask',
    question: text,
    options: [{ label: 'Staging' }, { label: 'Production' }],
  })
  await login(page, { next: '/?channel=general' })

  const card = page.locator(`#question-${message.id}`)
  await expect(card).toHaveAttribute('data-kind', 'ask')
  await expect(card.locator('strong')).toHaveText('staging')
  await expect(card).not.toContainText('Poll')
  await expect(card.locator('[id^="question-answer-count-"]')).toHaveCount(0)

  await card.locator(`#question-option-${message.question.options[0].id}`).click()

  await expect(card).toHaveAttribute('data-closed', 'true')
  await expect(card.locator(`#question-status-${message.id}`)).toContainText('Answered by')
})

test('a multi-select ask sends its checked options together', async ({ page, request }) => {
  const message = await sendPrompt(request, {
    kind: 'ask',
    question: `Which checks ${Date.now()}?`,
    multi_select: true,
    options: [{ label: 'Lint' }, { label: 'Types' }, { label: 'Tests' }],
  })
  await login(page, { next: '/?channel=general' })

  const card = page.locator(`#question-${message.id}`)
  const [lint, , tests] = message.question.options
  await card.locator(`#question-option-${lint.id}`).click()
  await card.locator(`#question-option-${tests.id}`).click()
  await card.locator(`#question-send-${message.id}`).click()

  await expect(card).toHaveAttribute('data-closed', 'true')
  await expect(card.locator(`#question-option-${lint.id}`)).toHaveAttribute('aria-pressed', 'true')
  await expect(card.locator(`#question-option-${tests.id}`)).toHaveAttribute('aria-pressed', 'true')
})

test('a permission request tints its options and leaves the transcript once answered', async ({ page, request }) => {
  const message = await sendPrompt(request, {
    kind: 'permission',
    question: `Run \`mix test\` ${Date.now()}?`,
    options: [
      { label: 'Allow once', kind: 'allow_once' },
      { label: 'Reject', kind: 'reject' },
    ],
  })
  await login(page, { next: '/?channel=general' })

  const card = page.locator(`#question-${message.id}`)
  await expect(card).toHaveAttribute('data-kind', 'permission')
  const [allow, reject] = message.question.options
  await expect(card.locator(`#question-option-${allow.id}`)).toHaveAttribute('data-option-kind', 'allow_once')
  await expect(card.locator(`#question-option-${reject.id}`)).toHaveAttribute('data-option-kind', 'reject')

  await card.locator(`#question-option-${allow.id}`).click()

  await expect(card).toHaveCount(0)
})
