import SwiftUI

extension View {
    @ViewBuilder
    func platformPinPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item) { value in
            content(value)
                .noctyraSheetPresentation()
        }
        #endif
    }

    @ViewBuilder
    func platformPinPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented) {
            content()
                .noctyraSheetPresentation()
        }
        #endif
    }
}
