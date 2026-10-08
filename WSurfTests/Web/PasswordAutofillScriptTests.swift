// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
struct PasswordAutofillScriptTests {
    private final class Sink: NSObject, WKScriptMessageHandler {
        var body: [String: Any]?
        var selections: [[String: Any]] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            body = message.body as? [String: Any]
            if let body, body["action"] as? String == "select" {
                selections.append(body)
            }
        }
    }

    private func load(_ html: String) async throws -> (BrowserPage, Sink) {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let sink = Sink()
        configuration.userContentController.add(sink, contentWorld: PasswordAutofill.world, name: "wsurfPasswords")
        BrowserPage.installBridge(in: configuration.userContentController, world: PasswordAutofill.world)
        configuration.userContentController.addUserScript(WKUserScript(
            source: PasswordAutofillScript.source, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: PasswordAutofill.world
        ))
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration), context: context)
        view.loadHTMLString("<!doctype html>" + html, baseURL: URL(string: "https://login.example/"))
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        _ = try await view.callAsyncJavaScript("globalThis.__wsurfPasswords.setEnabled(true);", arguments: [:], in: nil, contentWorld: PasswordAutofill.world)
        sink.body = nil
        return (view, sink)
    }

    private func select(in view: BrowserPage, sink: Sink) async throws -> String {
        _ = try await view.callAsyncJavaScript("document.getElementById('password').focus();", arguments: [:], in: nil, contentWorld: PasswordAutofill.world)
        #expect(await waitUntil { sink.body?["token"] is String })
        return try #require(sink.body?["token"] as? String)
    }

    private func fill(_ token: String, in view: BrowserPage) async throws -> Int {
        let result = try await view.callAsyncJavaScript(
            "return globalThis.__wsurfPasswords.fill(token,url,login);",
            arguments: ["token": token, "url": "https://login.example/", "login": ["username": "ada@example.test", "password": "dummy-secret"]],
            in: nil, contentWorld: PasswordAutofill.world
        )
        return try #require(result as? Int)
    }

    @Test(.boundedWebViews) func fillsOnlyLoginFieldsRedactsTheirValuesAndDoesNotSubmit() async throws {
        let (view, sink) = try await load(#"""
        <form onsubmit="window.submitted=true; return false">
        <input id="username" autocomplete="username"><input id="password" type="password" autocomplete="current-password">
        <input id="hidden" type="password" style="display:none"><input id="code" autocomplete="one-time-code">
        </form><form><input id="other" type="password"></form>
        """#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 2)
        #expect(try await view.evaluateJavaScript("username.value") as? String == "ada@example.test")
        #expect(try await view.evaluateJavaScript("password.value") as? String == "dummy-secret")
        #expect(try await view.evaluateJavaScript("hidden.value+code.value+other.value") as? String == "")
        #expect(try await view.evaluateJavaScript("!!window.submitted") as? Bool == false)
        let observation = await PageDriver.readRenderedPage(view)
        #expect(!observation.contains("dummy-secret"))
        #expect(!observation.contains("ada@example.test"))
        #expect(try await fill(token, in: view) == 0)
    }

    @Test(.boundedWebViews) func neverOffersSavedLoginsForRegistration() async throws {
        let (view, sink) = try await load(#"""
        <form><input id="username" autocomplete="username" value="ada">
        <input id="password" type="password" autocomplete="new-password" value="new-secret">
        <input id="confirmation" type="password" autocomplete="new-password" value="different"></form>
        """#)
        _ = try await view.callAsyncJavaScript("password.focus();", arguments: [:], in: nil, contentWorld: PasswordAutofill.world)
        #expect(sink.body?["token"] as? String == nil)
        #expect(try await fill(UUID().uuidString, in: view) == 0)
    }

    @Test(.boundedWebViews) func refusesChangedURLAndPageCannotAccessBridgeOrForgeSave() async throws {
        let (view, sink) = try await load(#"""
        <form id="form"><input id="username" autocomplete="username"><input id="password" type="password"></form>
        """#)
        #expect(try await view.evaluateJavaScript("typeof globalThis.__wsurfPasswords") as? String == "undefined")
        _ = try await view.evaluateJavaScript("form.dispatchEvent(new SubmitEvent('submit', {bubbles:true}));")
        #expect(sink.body == nil)
        let token = try await select(in: view, sink: sink)
        _ = try await view.evaluateJavaScript("history.pushState({},'', '/changed');")
        #expect(try await fill(token, in: view) == 0)
    }

    @Test(.boundedWebViews) func disabledManagerCannotFillCredentials() async throws {
        let (view, sink) = try await load(#"<form><input id="username" autocomplete="username"><input id="password" type="password" value="dummy-secret"></form>"#)
        let token = try await select(in: view, sink: sink)
        _ = try await view.callAsyncJavaScript("globalThis.__wsurfPasswords.setEnabled(false);", arguments: [:], in: nil, contentWorld: PasswordAutofill.world)
        #expect(try await fill(token, in: view) == 0)

    }

    @Test(.boundedWebViews) func refusesFormsThatSendPasswordsToAnotherOrigin() async throws {
        let (view, sink) = try await load(#"""
        <form action="https://other.example/post"><input id="username" autocomplete="username"><input id="password" type="password"></form>
        """#)
        _ = try await view.callAsyncJavaScript("password.focus();", arguments: [:], in: nil, contentWorld: PasswordAutofill.world)
        #expect(try await fill(UUID().uuidString, in: view) == 0)
        #expect(sink.body?["token"] as? String == nil)
    }

    @Test(.boundedWebViews) func componentInputsUseTheirOuterFormAndHostMetadata() async throws {
        let (view, sink) = try await load(#"""
        <form id="login" autocomplete="off" onsubmit="window.submitted=true; return false">
          <login-input id="account" name="username" autocomplete="username">
            <template shadowrootmode="open"><input type="text"></template>
          </login-input>
          <login-input id="secret" name="password" autocomplete="current-password">
            <template shadowrootmode="open"><input type="password"></template>
          </login-input>
        </form>
        <form><input id="other" type="password"></form>
        """#)
        _ = try await view.callAsyncJavaScript(
            "document.getElementById('secret').shadowRoot.querySelector('input').focus();",
            arguments: [:], in: nil, contentWorld: PasswordAutofill.world
        )
        #expect(await waitUntil { sink.body?["token"] is String })
        let token = try #require(sink.body?["token"] as? String)
        #expect(try await fill(token, in: view) == 2)
        #expect(try await view.evaluateJavaScript("account.shadowRoot.querySelector('input').value") as? String == "ada@example.test")
        #expect(try await view.evaluateJavaScript("secret.shadowRoot.querySelector('input').value") as? String == "dummy-secret")
        #expect(try await view.evaluateJavaScript("other.value") as? String == "")
        #expect(try await view.evaluateJavaScript("!!window.submitted") as? Bool == false)
    }

    @Test(.boundedWebViews) func hiddenComponentHostNeverQualifiesForPasswordFilling() async throws {
        let (view, sink) = try await load(#"""
        <form><input id="password" type="password" autocomplete="current-password">
          <login-input id="hidden-account" autocomplete="username" style="visibility:hidden">
            <template shadowrootmode="open"><input type="text" style="visibility:visible"></template>
          </login-input>
        </form>
        """#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
        #expect(try await view.evaluateJavaScript("document.getElementById('hidden-account').shadowRoot.querySelector('input').value") as? String == "")
    }

    @Test(.boundedWebViews) func movingFocusInvalidatesTheSuggestedLogin() async throws {
        let (view, sink) = try await load(#"<form><input id="password" type="password"><input id="other" autocomplete="one-time-code"></form>"#)
        let token = try await select(in: view, sink: sink)
        _ = try await view.evaluateJavaScript("other.focus();")
        #expect(try await fill(token, in: view) == 0)
        #expect(try await view.evaluateJavaScript("password.value + other.value") as? String == "")
    }

    @Test(.boundedWebViews) func usernameFirstStepFillsOnlyTheAccountWithoutSubmitting() async throws {
        let (view, sink) = try await load(#"<form onsubmit="window.submitted=true; return false"><input id="password" autocomplete="username"><button>Continue</button></form>"#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
        #expect(try await view.evaluateJavaScript("password.value") as? String == "ada@example.test")
        #expect(try await view.evaluateJavaScript("!!window.submitted") as? Bool == false)
    }

    @Test(.boundedWebViews, arguments: [false, true])
    func offersPasswordOnFirstFocusAfterUsernameStep(moving: Bool) async throws {
        let (view, sink) = try await load(#"""
        <form id="login"><input id="password" autocomplete="username"><button id="next" type="button">Next</button></form>
        <script>
          next.onclick = () => {
            login.innerHTML = '<input id="password" type="password" autocomplete="current-password">';
            const field = document.getElementById('password');
            if (!window.moving) field.style.opacity = '0';
            field.focus();
            for (let tick = 1; tick <= 8; tick++) {
              setTimeout(() => {
                if (window.moving) field.style.transform = `translateY(${tick * 10}px)`;
                if (tick === 8) {
                  field.style.opacity = '1';
                  window.stepReady = true;
                }
              }, tick * 30);
            }
          };
        </script>
        """#)
        _ = try await select(in: view, sink: sink)
        sink.selections = []
        _ = try await view.callAsyncJavaScript(
            "window.moving = moving; document.getElementById('next').click();",
            arguments: ["moving": moving], in: nil, contentWorld: .page
        )
        #expect(try await waitUntil(timeout: .seconds(3)) {
            try await view.evaluateJavaScript("window.stepReady === true") as? Bool == true && !sink.selections.isEmpty
        })
        let selection = try #require(sink.selections.first)
        let rect = try #require(selection["rect"] as? [String: Double])
        let top = try #require(try await view.evaluateJavaScript("password.getBoundingClientRect().y") as? Double)
        #expect(abs((rect["y"] ?? -1) - top) < 1)
        #expect(sink.selections.count == 1)
        let token = try #require(selection["token"] as? String)
        #expect(try await fill(token, in: view) == 1)
        #expect(try await view.evaluateJavaScript("password.value") as? String == "dummy-secret")
    }

    @Test(.boundedWebViews) func leavingThePasswordFieldCancelsItsPendingSuggestions() async throws {
        let (view, sink) = try await load(#"""
        <form><input id="password" type="password" style="opacity:0"><input id="other" autocomplete="one-time-code"></form>
        """#)
        _ = try await view.evaluateJavaScript("password.focus(); other.focus(); password.style.opacity = '1';")
        _ = try await view.callAsyncJavaScript(
            "await new Promise(resolve => setTimeout(resolve, 1200));", arguments: [:], in: nil, contentWorld: .page
        )
        #expect(sink.selections.isEmpty)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
    }

    @Test(.boundedWebViews, arguments: ["disabled", "expired", "dismissed", "typing"])
    func cancelledOrExpiredFocusDoesNotOpenSuggestionsWhenTheFieldAppears(reason: String) async throws {
        let (view, sink) = try await load(#"<input id="password" type="password" style="opacity:0">"#)
        let typed = try await view.callAsyncJavaScript(
            """
            const field = document.getElementById('password');
            field.focus();
            let typed = false;
            if (reason === 'disabled') globalThis.__wsurfPasswords.setEnabled(false);
            else if (reason === 'expired') await new Promise(resolve => setTimeout(resolve, 1200));
            else if (reason === 'dismissed') field.dispatchEvent(new Event('contextmenu', {bubbles:true}));
            else {
              field.addEventListener('input', event => { typed = event.isTrusted; }, {once:true});
              document.execCommand('insertText', false, 'a');
            }
            field.style.opacity = '1';
            await new Promise(resolve => setTimeout(resolve, 1200));
            return typed;
            """,
            arguments: ["reason": reason], in: nil, contentWorld: PasswordAutofill.world
        )
        if reason == "typing" { #expect(typed as? Bool == true) }
        #expect(sink.selections.isEmpty)
    }

    @Test(.boundedWebViews) func mutationsAloneDoNotStartSuggestions() async throws {
        let (view, sink) = try await load(#"<div id="fields"></div>"#)
        _ = try await view.callAsyncJavaScript(
            """
            document.getElementById('fields').innerHTML = '<input id="password" type="password">';
            await new Promise(resolve => setTimeout(resolve, 1200));
            """, arguments: [:], in: nil, contentWorld: .page
        )
        #expect(sink.selections.isEmpty)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
    }

    @Test(.boundedWebViews) func recognizesAFormlessAccountStepWithWebAuthnMetadata() async throws {
        let (view, sink) = try await load(#"""
        <div id="sign_in_form"><div><div><div><div><input id="password" autocomplete="username webauthn"></div></div></div></div>
          <button type="submit">Continue</button><button>Sign in with Passkey</button>
        </div>
        <div><input id="unrelated" autocomplete="username"><button>Continue</button></div>
        """#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
        #expect(try await view.evaluateJavaScript("password.value") as? String == "ada@example.test")
        #expect(try await view.evaluateJavaScript("unrelated.value") as? String == "")
    }

    @Test(.boundedWebViews) func recognizesAFormlessPasswordStepWithoutMergingAnotherLogin() async throws {
        let (view, sink) = try await load(#"""
        <div><input id="password" type="password" autocomplete="current-password"><button>Sign In</button></div>
        <div><input id="unrelated" type="password"><button>Sign In</button></div>
        """#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
        #expect(try await view.evaluateJavaScript("password.value") as? String == "dummy-secret")
        #expect(try await view.evaluateJavaScript("unrelated.value") as? String == "")
    }

    @Test(.boundedWebViews) func standalonePasswordDoesNotRequireAFormOrSubmitButton() async throws {
        let (view, sink) = try await load(#"<input id="password" type="password">"#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 1)
        #expect(try await view.evaluateJavaScript("password.value") as? String == "dummy-secret")
    }

    @Test(.boundedWebViews) func unlabelledComponentFieldsShareOwnershipWithoutEnglishActions() async throws {
        let (view, sink) = try await load(#"""
        <section>
          <div><input id="account"></div>
          <div><input id="password" type="password"><button type="button" aria-pressed="false">👁</button></div>
          <button type="button">Continuer</button>
        </section>
        <section><input id="unrelated" type="password"><button>Weiter</button></section>
        """#)
        let token = try await select(in: view, sink: sink)
        #expect(try await fill(token, in: view) == 2)
        #expect(try await view.evaluateJavaScript("account.value") as? String == "ada@example.test")
        #expect(try await view.evaluateJavaScript("unrelated.value") as? String == "")
    }

    @Test(.boundedWebViews) func disabledPasswordStillBlocksSubmissionCompletion() async throws {
        let (view, _) = try await load(#"<form><input id="password" type="password" disabled></form>"#)
        let result = try await view.callAsyncJavaScript(
            "return globalThis.__wsurfAutofillForms.summary().passwords;", arguments: [:],
            in: nil, contentWorld: PasswordAutofill.world
        )
        #expect(result as? Int == 1)
    }
}
