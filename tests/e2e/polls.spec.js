const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function login(page, next) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass', next }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
}

test('a member sends a poll, votes, answers Other and ends it', async ({ page }) => {
  await login(page, '/?channel=general')

  const question = `Lunch ${Date.now()}?`

  await page.locator('#open-poll-button').click()
  const form = page.locator('#poll-form')
  await expect(form).toBeVisible()

  await form.locator('#poll-question').fill(question)
  await form.locator('#poll-option-input-0').fill('Soup')
  await form.locator('#poll-option-input-1').fill('Salad')
  await form.locator('#add-poll-option').click()
  await form.locator('#poll-option-input-2').fill('Tacos')
  await form.locator('#poll-allow-other').check()
  await form.locator('#send-poll-button').click()

  await expect(form).toBeHidden()
  const card = page.locator('[id^="poll-"][data-closed]', { hasText: question })
  await expect(card).toBeVisible()

  const tacos = card.locator('[id^="poll-option-"]', { hasText: 'Tacos' }).first()
  await tacos.click()
  await expect(tacos).toHaveAttribute('aria-pressed', 'true')
  await expect(card.locator('[id^="poll-voter-count-"]')).toHaveText('1 vote')

  // A single-choice poll takes one answer: Other replaces the option.
  await card.locator('[id^="poll-other-"][aria-pressed]').click()
  await card.locator('[id^="poll-other-text-"]').fill('Noodles')
  await card.locator('[id^="poll-other-form-"] button[type="submit"]').click()
  await expect(card.locator('[id^="poll-other-answers-"]')).toContainText('Noodles')
  await expect(tacos).toHaveAttribute('aria-pressed', 'false')

  page.once('dialog', dialog => dialog.accept())
  await card.locator('[id^="poll-close-"]').click()
  await expect(card).toHaveAttribute('data-closed', 'true')
  await expect(tacos).toBeDisabled()
})
