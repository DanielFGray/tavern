const { test, expect } = require('@playwright/test')

const { baseURL, command, login, unique } = require('./support')

// A direct message between two browsers: one member opens it from the other's profile card,
// the other finds it in the sidebar with an unread badge, and replies arrive live both ways.

async function sendMessage(page, text) {
  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(text)
  await page.getByRole('button', { name: 'Send message' }).click()
}

test('a member opens a DM from a profile card and the peer answers', async ({ browser, page, request, isMobile }, testInfo) => {
  test.skip(isMobile, 'the member list that opens the card is a drawer on a phone')

  const marker = unique(testInfo)
  const peer = {
    email: `e2e_dm_${marker}@example.com`,
    username: `e2e_dm_${marker}`,
    display_name: `Peer ${marker}`,
    password: 'supersecurepass',
  }
  const { user } = await command(request, 'upsert_user', peer)

  await login(page, { next: '/?channel=general' })
  await page.locator(`#member-presence-${user.id} button[data-profile-user-id]`).click()
  await page.locator('#profile-card-message').click()

  await expect(page).toHaveURL(/[?&]dm=/)
  await expect(page.locator('#direct-message-title h1')).toHaveText(peer.display_name)
  await expect(page.locator('#direct-message-privacy')).toContainText('Only the two of you')
  await expect(page.locator('#open-channel-pins')).toHaveCount(0)
  await expect(page.locator('#message-form p.is-editor-empty')).toHaveAttribute(
    'data-placeholder',
    `Message ${peer.display_name}`,
  )
  const dmLink = page.locator('#direct-message-nav a', { hasText: peer.display_name })
  await expect(dmLink).toBeVisible()

  await sendMessage(page, `hello ${marker}`)
  const sent = page.locator(`#message-list [data-markdown-source="hello ${marker}"]`)
  await expect(sent).toBeVisible()

  // A DM has no pins and no threads, so its message menu offers neither.
  await sent.click()
  const menuButton = page.locator('[id^="open-message-actions-"]').last()
  await menuButton.click()
  const menu = page.locator('[id^="message-actions-menu-"]').last()
  await expect(menu).toBeVisible()
  await expect(menu.locator('[id^="pin-message-"]')).toHaveCount(0)
  await expect(menu.locator('[id^="create-thread-menu-"]')).toHaveCount(0)
  await page.keyboard.press('Escape')

  const peerContext = await browser.newContext({ baseURL })
  const peerPage = await peerContext.newPage()
  await login(peerPage, { ...peer, next: '/?channel=general' })

  const peerLink = peerPage.locator('#direct-message-nav a').first()
  await expect(peerLink.locator('[id^="dm-unread-"]')).toHaveText('1')
  await peerLink.click()
  await expect(peerPage.locator(`#message-list [data-markdown-source="hello ${marker}"]`)).toBeVisible()
  await expect(peerLink.locator('[id^="dm-unread-"]')).toHaveCount(0)

  await sendMessage(peerPage, `back at you ${marker}`)
  await expect(page.locator(`#message-list [data-markdown-source="back at you ${marker}"]`)).toBeVisible()

  await peerContext.close()
})
