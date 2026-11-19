const { test, expect } = require('@playwright/test')
const { command, login, unique } = require('./support')

test('a manager deletes a thread from its menu and a follower sees it vanish', async ({ page, browser, request }, testInfo) => {
  // A fresh member and message per run, so a rerun never finds an earlier run's thread.
  const stamp = unique(testInfo)
  const member = { email: `e2e-td-${stamp}@example.com`, username: `e2e_td_${stamp}` }
  await command(request, 'upsert_user', { ...member, display_name: 'Thread Follower' })

  await login(page, { next: '/?channel=general' })
  const { message: starter } = await command(request, 'create_message', {
    channel_slug: 'general',
    username: 'e2e_user',
    body: `doomed starter ${stamp}`,
  })
  await page.locator(`#message-list [data-markdown-source="doomed starter ${stamp}"]`).click()
  await page.locator(`#create-thread-${starter.id}`).click()
  const panel = page.locator(`#thread-panel-${starter.id}`)
  await expect(panel).toBeVisible()
  const composer = page.locator('#thread-message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`doomed reply ${stamp}`)
  await page.locator('#send-thread-message-button').click()
  await expect(panel).toContainText(`doomed reply ${stamp}`)

  // The member opens the thread and follows it, so it is in their sidebar.
  const context = await browser.newContext({ baseURL: testInfo.project.use.baseURL })
  const memberPage = await context.newPage()
  await login(memberPage, { ...member, next: '/?channel=general' })
  const pill = memberPage.locator(`#thread-summary-${starter.id}`)
  await expect(pill).toBeVisible()
  await pill.click()
  await expect(memberPage.locator(`#thread-panel-${starter.id}`)).toBeVisible()
  await memberPage.locator(`#toggle-follow-thread-${starter.id}`).click()
  const sidebarEntry = memberPage.locator('[id^="sidebar-thread-"]:not([id^="sidebar-thread-unread-"])')
  await expect(sidebarEntry).toHaveCount(1)
  // A member holds no manage_messages, so the menu offers no delete.
  await expect(memberPage.locator(`#thread-actions-${starter.id}`)).toHaveCount(0)

  // The owner confirms the delete from the panel menu.
  await page.locator(`#thread-actions-${starter.id}`).click()
  await page.locator(`#prompt-delete-thread-${starter.id}`).click()
  await expect(page.locator(`#confirm-delete-thread-${starter.id}`)).toBeVisible()
  await page.locator(`#cancel-delete-thread-${starter.id}`).click()
  await expect(page.locator(`#prompt-delete-thread-${starter.id}`)).toBeVisible()
  await expect(panel).toBeVisible()
  await page.locator(`#prompt-delete-thread-${starter.id}`).click()
  await page.locator(`#delete-thread-${starter.id}`).click()

  // Every view drops it: the owner's panel and pill, and the member's open panel, pill and sidebar entry.
  for (const view of [page, memberPage]) {
    await expect(view.locator(`#thread-panel-${starter.id}`)).toHaveCount(0)
    await expect(view.locator(`#thread-summary-${starter.id}`)).toHaveCount(0)
  }
  await expect(sidebarEntry).toHaveCount(0)
  await expect(memberPage.locator('#flash-info')).toContainText('Thread deleted')

  // The starter stays: only its thread went.
  await expect(page.locator(`#messages-${starter.id}`)).toBeVisible()
  await context.close()
})
