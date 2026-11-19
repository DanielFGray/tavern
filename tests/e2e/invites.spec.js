const { test, expect } = require('@playwright/test')

const { command, unique } = require('./support')

test('invite-only registration requires a valid code and consumes one use', async ({ page }, testInfo) => {
  const suffix = unique(testInfo)

  await command(page.request, 'set_registration_mode', { mode: 'invite_only' })
  const { invite } = await command(page.request, 'create_invite', { max_uses: '1' })

  // The gate shows the invite field.
  await page.goto('/register')
  await expect(page.locator("input[name='user[invite_code]']")).toBeVisible()

  // A bad code refuses the registration and creates no account.
  const fillForm = async (email, code) => {
    await page.goto('/register')
    await page.locator('#registration-form input[name="user[email]"]').fill(email)
    await page.locator('#registration-form input[name="user[username]"]').fill(`late_${suffix}`)
    await page.locator('#registration-form input[name="user[display_name]"]').fill('Late Arrival')
    await page.locator('#registration-form input[name="user[password]"]').fill('supersecurepass')
    await page.locator('#registration-form input[name="user[invite_code]"]').fill(code)
    await page.locator('#registration-submit').click()
  }

  await fillForm(`nogood-${suffix}@example.com`, 'notacode')
  await expect(page.locator('#flash-group')).toContainText('That invite code is not valid.')
  await expect(page).toHaveURL(/\/register/)

  // The valid code registers the account and signs it in.
  await fillForm(`late-${suffix}@example.com`, invite.code)
  await expect(page).toHaveURL(/\/($|\?)/)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })

  // The invite allowed exactly one use, so the next visitor is refused again.
  await page.context().clearCookies()
  await fillForm(`again-${suffix}@example.com`, invite.code)
  await expect(page.locator('#flash-group')).toContainText('That invite code is not valid.')

  await command(page.request, 'set_registration_mode', { mode: 'open' })
})

test('open registration needs no invite code', async ({ page }, testInfo) => {
  const suffix = unique(testInfo)

  await command(page.request, 'set_registration_mode', { mode: 'open' })

  await page.goto('/register')
  await expect(page.locator("input[name='user[invite_code]']")).toHaveCount(0)

  await page.locator('#registration-form input[name="user[email]"]').fill(`free-${suffix}@example.com`)
  await page.locator('#registration-form input[name="user[username]"]').fill(`free_${suffix}`)
  await page.locator('#registration-form input[name="user[display_name]"]').fill('Free Arrival')
  await page.locator('#registration-form input[name="user[password]"]').fill('supersecurepass')
  await page.locator('#registration-submit').click()

  await expect(page).toHaveURL(/\/($|\?)/)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
})
