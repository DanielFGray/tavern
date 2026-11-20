const { test, expect } = require('@playwright/test')
const { command, login, unique } = require('./support')

test('a thread creator renames it from the panel menu and a follower sees the new title live', async ({ page, browser, request }, testInfo) => {
  // A fresh member and message per run, so a rerun never finds an earlier run's thread.
  const stamp = unique(testInfo)
  const member = { email: `e2e-tr-${stamp}@example.com`, username: `e2e_tr_${stamp}` }
  await command(request, 'upsert_user', { ...member, display_name: 'Thread Follower' })

  await login(page, { next: '/?channel=general' })
  const { message: starter } = await command(request, 'create_message', {
    channel_slug: 'general',
    username: 'e2e_user',
    body: `rename starter ${stamp}`,
  })
  await page.locator(`#message-list [data-markdown-source="rename starter ${stamp}"]`).click()
  await page.locator(`#create-thread-${starter.id}`).click()
  const panel = page.locator(`#thread-panel-${starter.id}`)
  await expect(panel).toBeVisible()

  // The member opens the thread and follows it, so it is in their sidebar.
  const context = await browser.newContext({ baseURL: testInfo.project.use.baseURL })
  const memberPage = await context.newPage()
  await login(memberPage, { ...member, next: '/?channel=general' })
  await memberPage.locator(`#thread-summary-${starter.id}`).click()
  await memberPage.locator(`#toggle-follow-thread-${starter.id}`).click()
  const sidebarEntry = memberPage.locator('[id^="sidebar-thread-"]:not([id^="sidebar-thread-unread-"])')
  await expect(sidebarEntry).toHaveCount(1)
  // Until someone names the thread, its pill shows no title: the starter above it is the title.
  await expect(memberPage.locator(`#thread-summary-${starter.id}`)).toBeVisible()
  await expect(memberPage.locator(`#thread-summary-title-${starter.id}`)).toHaveCount(0)
  // A plain member neither created the thread nor manages messages: no menu, so no rename.
  await expect(memberPage.locator(`#rename-thread-${starter.id}`)).toHaveCount(0)

  // The creator opens the menu, edits the title in place and saves with Enter.
  const title = page.locator(`#thread-title-${starter.id}`)
  const input = page.locator(`#thread-rename-input-${starter.id}`)
  await page.locator(`#thread-actions-${starter.id}`).click()
  await page.locator(`#rename-thread-${starter.id}`).click()
  await expect(input).toBeVisible()
  await expect(title).toBeHidden()
  await expect(input).toBeFocused()

  // Escape cancels and leaves the title as it was.
  await input.fill('Not saved')
  await input.press('Escape')
  await expect(input).toBeHidden()
  await expect(title).toContainText(`rename starter ${stamp}`.slice(0, 40))

  const newTitle = `Renamed ${stamp}`.slice(0, 40)
  await page.locator(`#thread-actions-${starter.id}`).click()
  await page.locator(`#rename-thread-${starter.id}`).click()
  await input.fill(newTitle)
  await input.press('Enter')

  await expect(title).toBeVisible()
  await expect(title).toHaveText(newTitle)
  await expect(page.locator(`#thread-summary-title-${starter.id}`)).toHaveText(newTitle)
  await expect(memberPage.locator(`#thread-title-${starter.id}`)).toHaveText(newTitle)
  await expect(memberPage.locator(`#thread-summary-title-${starter.id}`)).toHaveText(newTitle)
  await expect(sidebarEntry).toContainText(newTitle)
  await context.close()
})
