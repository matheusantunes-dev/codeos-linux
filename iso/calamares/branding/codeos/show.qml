/* Apresentação durante a instalação do CodeOS */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    Timer {
        interval: 9000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0A1B3C" }
        Image {
            id: logo1
            source: "logo.png"
            width: 128; height: 128
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top; anchors.topMargin: 60
        }
        Text {
            anchors.top: logo1.bottom; anchors.topMargin: 30
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "#E6EDF7"; font.pixelSize: 22
            text: qsTr("Welcome to CodeOS: familiar like Windows, light and fast, ready to program.")
        }
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0A1B3C" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "#E6EDF7"; font.pixelSize: 20
            text: qsTr("The shortcuts you know: Super opens the menu, Super+E the files, Super+V the clipboard history, Super+Shift+S snips the screen.")
        }
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0A1B3C" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "#E6EDF7"; font.pixelSize: 20
            text: qsTr("For developers: Git, GitHub, Docker, Podman, Distrobox and language versions with mise. The welcome screen sets everything up after the first login.")
        }
    }

    function onActivate() { presentation.currentSlide = 0; }
    function onLeave() { }
}
