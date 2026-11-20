const { test, expect } = require('@playwright/test')
const { command, unique } = require('./support')

const baseURL = 'http://127.0.0.1:4001'

async function loginAs(page, account) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ password: 'supersecurepass', next: '/', ...account }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
}

test('a member resets a forgotten password from the emailed link, and every old session ends', async ({
  page,
  request,
  browser,
}, testInfo) => {
  const stamp = unique(testInfo)
  const account = { email: `e2e-reset-${stamp}@example.com`, username: `e2e_reset_${stamp}` }
  await command(request, 'upsert_user', { ...account, display_name: 'Forgetful Member', verified: false })

  // A session that exists before the reset, in its own browser context.
  const oldContext = await browser.newContext()
  const oldPage = await oldContext.newPage()
  await loginAs(oldPage, account)
  await expect(oldPage.locator('#verification-banner')).toContainText(account.email)

  // The login page offers the link, and the request page answers every email alike.
  await page.goto('/login')
  await page.locator('#forgot-password').click()
  await expect(page.locator('#password-reset-request-form')).toBeVisible()
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
  await page.locator('#password-reset-request-form input[type="email"]').fill(account.email)
  await page.locator('#password-reset-request-submit').click()
  await expect(page.locator('#password-reset-sent')).toContainText('If that email belongs to an account')
  await page.screenshot({ path: testInfo.outputPath('reset-request-sent.png') })

  // The same reply for an email with no account.
  await page.goto('/users/reset-password')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
  await page.locator('#password-reset-request-form input[type="email"]').fill(`nobody-${stamp}@example.com`)
  await page.locator('#password-reset-request-submit').click()
  await expect(page.locator('#password-reset-sent')).toContainText('If that email belongs to an account')

  // The link sets a new password.
  const { mail } = await command(request, 'capture_password_reset_mail', { email: account.email })
  expect(mail.to).toBe(account.email)
  await page.goto(mail.path)
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
  await expect(page.locator('#password-reset-form')).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('reset-form.png') })

  const password = page.locator('#password-reset-form input[type="password"]')
  await password.fill('short')
  await expect(page.locator('#password-reset-form')).toContainText('should be at least 12 character')
  await password.fill('a brand new password')
  await page.locator('#password-reset-submit').click()

  await expect(page).toHaveURL(/\/login$/)
  await expect(page.locator('#flash-info')).toContainText('Your password is changed')
  await page.screenshot({ path: testInfo.outputPath('reset-done-login.png') })

  // The old session is gone: its next page load lands on the login page.
  await oldPage.goto('/')
  await expect(oldPage).toHaveURL(/\/login$/)
  await oldContext.close()

  // The old password fails, the new one signs in.
  const form = page.locator('#login-form')
  await form.locator('input[type="email"]').fill(account.email)
  await form.locator('input[type="password"]').fill('supersecurepass')
  await page.locator('#login-submit').click()
  await expect(page.locator('#flash-error')).toContainText('Invalid email or password')

  await form.locator('input[type="email"]').fill(account.email)
  await form.locator('input[type="password"]').fill('a brand new password')
  await page.locator('#login-submit').click()
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
  // The link verified the email too: the banner that the unverified member had is gone.
  await expect(page.locator('#verification-banner')).toHaveCount(0)
  await expect(page.locator('#composer-locked-notice')).toHaveCount(0)
  await page.screenshot({ path: testInfo.outputPath('reset-member-verified.png') })

  // The used link now fails.
  await page.goto(mail.path)
  await expect(page.locator('#password-reset-invalid')).toContainText('This reset link does not work')
  await page.screenshot({ path: testInfo.outputPath('reset-link-used.png') })
})
