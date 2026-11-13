import SwiftUI

@main
struct CuvenApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Cuven max")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .preferredColorScheme(.dark)
        }
    }
}
