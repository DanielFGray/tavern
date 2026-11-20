const { test, expect } = require('@playwright/test')

const { command, login, openSidebar, unique } = require('./support')

// Every script the pages need runs under the policy: the app bundle from this origin and the
// root layout's inline theme script by its nonce. A blocked script shows up as a
// securitypolicyviolation event and a console error.
test('pages run their scripts under the script-src policy with no violation', async ({ page, request }, testInfo) => {
  const suffix = unique(testInfo)
  const account = {
    email: `test_csp_${suffix}@example.com`,
    username: `test_csp_${suffix}`,
    password: 'supersecurepass',
  }
  await command(request, 'upsert_user', account)

  const consoleErrors = []
  page.on('console', (message) => message.type() === 'error' && consoleErrors.push(message.text()))
  await page.addInitScript(() => {
    window.__cspViolations = []
    document.addEventListener('securitypolicyviolation', (event) =>
      window.__cspViolations.push(`${event.violatedDirective} ${event.blockedURI}`),
    )
  })
  const violations = () => page.evaluate(() => window.__cspViolations)

  await page.goto('/login')
  await page.waitForLoadState('load')
  expect(await violations()).toEqual([])

  await login(page, { ...account, next: '/?channel=general' })
  expect(await violations()).toEqual([])

  // The inline theme script handles the theme buttons' event, so a blocked script would leave
  // data-theme unset.
  await openSidebar(page)
  await page.locator('button[data-phx-theme="light"]').first().click()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

  await page.goto('/settings')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

  expect(await violations()).toEqual([])
  expect(consoleErrors.filter((text) => /Content Security Policy/i.test(text))).toEqual([])
})
