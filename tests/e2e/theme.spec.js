const { test, expect } = require('@playwright/test')

const { login, openSidebar, openUserMenu } = require('./support')

// The theme buttons sit in the sidebar footer, inside the drawer on a phone.
async function pickTheme(page, theme) {
  await openSidebar(page)
  await page.locator(`button[data-phx-theme="${theme}"]`).first().click()
}

// Skip colour transitions so computed styles and screenshots show the settled theme.
const settle = (page) =>
  page.addStyleTag({ content: '*, *::before, *::after { transition: none !important }' })

const surfaceColors = (page) =>
  page.evaluate(() => ({
    theme: document.documentElement.getAttribute('data-theme'),
    scheme: getComputedStyle(document.documentElement).colorScheme,
    sidebar: getComputedStyle(document.querySelector('#server-shell aside')).backgroundColor,
    main: getComputedStyle(document.querySelector('main')).backgroundColor,
  }))

test('theme toggle switches shell surfaces between light, dark and system', async ({ page }, testInfo) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await login(page)
  await settle(page)

  await pickTheme(page, 'light')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  const light = await surfaceColors(page)
  await page.screenshot({ path: testInfo.outputPath('light.png') })

  await pickTheme(page, 'dark')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark')
  const dark = await surfaceColors(page)
  await page.screenshot({ path: testInfo.outputPath('dark.png') })

  // The choice survives a full page load.
  await pickTheme(page, 'light')
  await page.reload()
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  await settle(page)
  await page.screenshot({ path: testInfo.outputPath('light-reloaded.png') })
  await pickTheme(page, 'dark')

  expect(light.scheme).toBe('light')
  expect(dark.scheme).toBe('dark')
  expect(light.main).not.toBe(dark.main)
  expect(light.sidebar).not.toBe(dark.sidebar)

  await pickTheme(page, 'system')
  await expect(page.locator('html')).not.toHaveAttribute('data-theme', /.+/)
  expect((await surfaceColors(page)).main).toBe(dark.main)
  await page.emulateMedia({ colorScheme: 'light' })
  expect((await surfaceColors(page)).main).toBe(light.main)
})

test('light theme applies to the settings page', async ({ page }, testInfo) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await login(page)
  await pickTheme(page, 'light')
  await openUserMenu(page)
  await page.locator('#user-menu-settings').click()
  await expect(page.locator('#settings-panel-title')).toBeVisible()
  await settle(page)
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  const bg = await page.evaluate(() => getComputedStyle(document.querySelector('main')).backgroundColor)
  expect(bg).toBe('oklch(0.92 0.004 286.32)')
  await page.screenshot({ path: testInfo.outputPath('settings-light.png') })
})
