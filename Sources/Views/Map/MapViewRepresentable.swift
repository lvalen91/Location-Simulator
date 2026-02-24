import SwiftUI
import MapKit

/// NSViewRepresentable wrapping MKMapView for full control over gestures,
/// overlays, annotations, and right-click context menus.
struct MapViewRepresentable: NSViewRepresentable {
    @Bindable var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = false

        // Reposition the scale view to bottom center after layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.repositionScaleView(in: mapView)
        }

        // Long press → teleport/route
        let longPress = NSPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)

        // Right click → context menu
        let rightClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightClick(_:)))
        rightClick.buttonMask = 0x2 // right button
        mapView.addGestureRecognizer(rightClick)

        context.coordinator.mapView = mapView
        return mapView
    }

    /// Find the built-in scale subview and reposition it to bottom center.
    private static func repositionScaleView(in mapView: MKMapView) {
        for subview in mapView.subviews {
            let className = String(describing: type(of: subview))
            if className.contains("Scale") || className.contains("scale") {
                subview.translatesAutoresizingMaskIntoConstraints = false
                // Remove existing constraints on this view
                for constraint in mapView.constraints where constraint.firstItem === subview || constraint.secondItem === subview {
                    mapView.removeConstraint(constraint)
                }
                NSLayoutConstraint.activate([
                    subview.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
                    subview.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -35)
                ])
                mapView.layoutSubtreeIfNeeded()
                return
            }
            // Check one level deeper
            for nested in subview.subviews {
                let nestedName = String(describing: type(of: nested))
                if nestedName.contains("Scale") || nestedName.contains("scale") {
                    nested.removeFromSuperview()
                    mapView.addSubview(nested)
                    nested.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        nested.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
                        nested.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -35)
                    ])
                    mapView.layoutSubtreeIfNeeded()
                    return
                }
            }
        }
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.appState = appState

        // Update map type
        if mapView.mapType != appState.mapType {
            mapView.mapType = appState.mapType
        }

        // Update current location marker
        context.coordinator.updateCurrentLocationMarker()

        // Update route overlays
        context.coordinator.updateRouteOverlays()

        // Update navigation overlay
        context.coordinator.updateNavigationOverlay()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        var appState: AppState
        weak var mapView: MKMapView?
        private var currentMarker: MKPointAnnotation?
        private var routeOverlays: [MKPolyline] = []
        private var navigationOverlay: MKPolyline?
        private var completedOverlay: MKPolyline?

        init(appState: AppState) {
            self.appState = appState
        }

        // MARK: - Marker

        func updateCurrentLocationMarker() {
            guard let mapView = mapView else { return }

            if let location = appState.spoofing.currentLocation {
                if currentMarker == nil {
                    let marker = MKPointAnnotation()
                    marker.title = "Spoofed Location"
                    mapView.addAnnotation(marker)
                    currentMarker = marker
                }
                currentMarker?.coordinate = location
                currentMarker?.subtitle = String(format: "%.6f, %.6f", location.latitude, location.longitude)
            } else if let marker = currentMarker {
                mapView.removeAnnotation(marker)
                currentMarker = nil
            }
        }

        // MARK: - Route Preview Overlays

        func updateRouteOverlays() {
            guard let mapView = mapView else { return }

            // Remove old overlays
            for overlay in routeOverlays { mapView.removeOverlay(overlay) }
            routeOverlays.removeAll()

            // Add calculated routes
            for route in appState.calculatedRoutes {
                let polyline = route.polyline
                routeOverlays.append(polyline)
                mapView.addOverlay(polyline, level: .aboveLabels)
            }

            // Zoom to fit routes
            if let first = appState.calculatedRoutes.first {
                var rect = first.polyline.boundingMapRect
                for route in appState.calculatedRoutes.dropFirst() {
                    rect = rect.union(route.polyline.boundingMapRect)
                }
                let padding = NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60)
                mapView.setVisibleMapRect(rect, edgePadding: padding, animated: true)
            }
        }

        // MARK: - Navigation Overlay

        func updateNavigationOverlay() {
            guard let mapView = mapView else { return }

            // Remove old navigation overlays
            if let old = navigationOverlay { mapView.removeOverlay(old) }
            if let old = completedOverlay { mapView.removeOverlay(old) }
            navigationOverlay = nil
            completedOverlay = nil

            let engine = appState.spoofing.navigation
            guard engine.isNavigating else { return }

            // Remaining route (blue)
            let remaining = engine.remainingRoute
            if remaining.count >= 2 {
                let overlay = MKPolyline(coordinates: remaining, count: remaining.count)
                mapView.addOverlay(overlay, level: .aboveLabels)
                navigationOverlay = overlay
            }

            // Completed route (gray)
            let completed = engine.completedRoute
            if completed.count >= 2 {
                let overlay = MKPolyline(coordinates: completed, count: completed.count)
                mapView.addOverlay(overlay, level: .aboveLabels)
                completedOverlay = overlay
            }
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)

            // Navigation overlays
            if polyline === completedOverlay {
                renderer.strokeColor = .systemGray
                renderer.lineWidth = 5
                renderer.alpha = 0.5
                return renderer
            }
            if polyline === navigationOverlay {
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 5
                return renderer
            }

            // Route preview overlays
            if let selectedIdx = appState.selectedRouteIndex,
               selectedIdx < routeOverlays.count,
               polyline === routeOverlays[selectedIdx] {
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 5
            } else {
                renderer.strokeColor = .systemGray
                renderer.lineWidth = 4
                renderer.alpha = 0.6
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKPointAnnotation else { return nil }
            let id = "CurrentLocation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = .systemBlue
            view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
            view.isDraggable = true
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                      didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending, let coord = view.annotation?.coordinate {
                appState.teleportTo(coord)
            }
        }

        // MARK: - Gestures

        @objc func handleLongPress(_ gesture: NSPressGestureRecognizer) {
            guard gesture.state == .ended, let mapView = mapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            // Default long press: teleport
            appState.teleportTo(coord)
        }

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let mapView = mapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)

            let menu = NSMenu()

            let teleportItem = NSMenuItem(title: "Teleport Here", action: #selector(contextTeleport(_:)), keyEquivalent: "")
            teleportItem.target = self
            teleportItem.representedObject = NSValue(mkCoordinate: coord)
            menu.addItem(teleportItem)

            menu.addItem(.separator())

            let fromItem = NSMenuItem(title: "Route From Here", action: #selector(contextRouteFrom(_:)), keyEquivalent: "")
            fromItem.target = self
            fromItem.representedObject = NSValue(mkCoordinate: coord)
            menu.addItem(fromItem)

            let toItem = NSMenuItem(title: "Route To Here", action: #selector(contextRouteTo(_:)), keyEquivalent: "")
            toItem.target = self
            toItem.representedObject = NSValue(mkCoordinate: coord)
            menu.addItem(toItem)

            menu.addItem(.separator())

            let copyItem = NSMenuItem(title: "Copy Coordinates", action: #selector(contextCopyCoords(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = NSValue(mkCoordinate: coord)
            menu.addItem(copyItem)

            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: mapView)
        }

        @objc private func contextTeleport(_ sender: NSMenuItem) {
            guard let val = sender.representedObject as? NSValue else { return }
            appState.teleportTo(val.mkCoordinateValue)
        }

        @objc private func contextRouteFrom(_ sender: NSMenuItem) {
            guard let val = sender.representedObject as? NSValue else { return }
            appState.setRouteFrom(val.mkCoordinateValue)
        }

        @objc private func contextRouteTo(_ sender: NSMenuItem) {
            guard let val = sender.representedObject as? NSValue else { return }
            appState.setRouteTo(val.mkCoordinateValue)
        }

        @objc private func contextCopyCoords(_ sender: NSMenuItem) {
            guard let val = sender.representedObject as? NSValue else { return }
            let coord = val.mkCoordinateValue
            let str = String(format: "%.6f, %.6f", coord.latitude, coord.longitude)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }
}
