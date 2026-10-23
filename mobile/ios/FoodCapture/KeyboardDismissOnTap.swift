import SwiftUI
#if os(iOS)
import UIKit

/// Dismisses the keyboard when the user taps anywhere outside a text field or control.
///
/// A SwiftUI `.onTapGesture` on a `Form` swallows the taps that activate its buttons, so
/// this installs a UIKit recognizer on the window instead: it runs alongside the controls
/// (`cancelsTouchesInView = false`) and ignores touches that land on inputs.
struct KeyboardDismissOnTap: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        DispatchQueue.main.async { attach(from: controller.view, coordinator: context.coordinator) }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.remove()
    }

    private func attach(from view: UIView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        coordinator.install(on: window)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var recognizer: UITapGestureRecognizer?

        func install(on view: UIView) {
            guard recognizer == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            recognizer = tap
        }

        func remove() {
            if let recognizer, let view = recognizer.view {
                view.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
        }

        @objc private func dismissKeyboard() {
            _ = MainActor.assumeIsolated {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
        }

        /// Let the controls under the tap handle it too; only dismiss from empty space,
        /// section text, and other non-input areas.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            MainActor.assumeIsolated {
                var view = touch.view
                while let current = view {
                    if current is UITextField || current is UITextView || current is UIControl {
                        return false
                    }
                    view = current.superview
                }
                return true
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

extension View {
    func keyboardDismissOnTap() -> some View { background(KeyboardDismissOnTap()) }
}

#else

extension View {
    /// No-op on macOS: clicking outside a field already moves focus.
    func keyboardDismissOnTap() -> some View { self }
}

#endif
