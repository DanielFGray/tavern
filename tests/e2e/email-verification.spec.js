const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function loginAs(page, payload, next = '/') {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ password: 'supersecurepass', next, ...payload }))
  await page.goto(url.toString())
}

test('an unverified member reads but cannot send until they open the emailed link', async ({ page, request }, testInfo) => {
  // A fresh member per run: both projects share one database, and verifying is one-way.
  const stamp = `${Date.now().toString(36)}${testInfo.project.name.length}`
  const email = `e2e-unv-${stamp}@example.com`
  const username = `e2e_unv_${stamp}`
  await command(request, 'upsert_user', { email, username, display_name: 'New Member', verified: false })

  await loginAs(page, { email, username })
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })

  const banner = page.locator('#verification-banner')
  await expect(banner).toContainText(email)
  await expect(page.locator('#resend-verification')).toBeVisible()
  await expect(page.locator('#composer-locked-notice')).toContainText('Verify your email to send messages.')
  await expect(page.locator('#message-form')).toHaveCount(0)
  await page.screenshot({ path: testInfo.outputPath('unverified-banner-and-locked-composer.png') })

  // The link opens in a second tab; the first tab unlocks without a reload.
  const { mail } = await command(request, 'capture_verification_mail', { email })
  expect(mail.to).toBe(email)
  const linkTab = await page.context().newPage()
  await linkTab.goto(mail.path)
  await expect(linkTab.locator('#flash-info')).toContainText('Your email is confirmed')
  await linkTab.close()

  await expect(banner).toHaveCount(0)
  await expect(page.locator('#composer-locked-notice')).toHaveCount(0)

  const body = `verified hello ${stamp}`
  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(body)
  await page.getByRole('button', { name: 'Send message' }).click()
  await expect(page.locator(`#message-list [data-markdown-source*="${body}"]`)).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('verified-member-sent.png') })
})

test('an owner sees the unverified badge and edits only the Unverified role permissions', async ({ page, request }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'the member list is a drawer on phones; the flow is the same')

  const stamp = Date.now().toString(36)
  const { user: member } = await command(request, 'upsert_user', {
    email: `e2e-unv-${stamp}@example.com`,
    username: `e2e_unv_${stamp}`,
    display_name: 'Pending Member',
    verified: false,
  })

  await loginAs(page, { email: 'e2e@example.com', username: 'e2e_user' })
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
  await expect(page.locator('#verification-banner')).toHaveCount(0)
  await expect(page.locator(`#member-unverified-${member.id}`)).toBeVisible()
  await page.locator(`#member-presence-${member.id}`).screenshot({ path: testInfo.outputPath('unverified-badge.png') })

  await page.goto('/settings?tab=roles')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
  const row = page.locator('#role-list li', { hasText: 'Unverified' })
  await expect(row).toContainText('unconfirmed emails')
  await expect(row.locator('[id^="delete-role-"]')).toHaveCount(0)
  await row.locator('[id^="edit-role-"]').click()

  const editor = page.locator('#role-edit-form')
  await expect(editor).toContainText('Edit Unverified')
  await expect(editor.locator('input[name="role[name]"]')).toHaveCount(0)
  await expect(page.locator('#role-permission-help')).toContainText('has not confirmed their email')
  await page.screenshot({ path: testInfo.outputPath('unverified-role-editor.png'), fullPage: true })
})
