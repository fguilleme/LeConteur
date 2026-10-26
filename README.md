# Le Conteur

[Français](https://github.com/fguilleme/LeConteur/blob/main/README.md) · [English](https://github.com/fguilleme/LeConteur/blob/main/README.en.md)

Le Conteur est un lecteur audio local pour iPhone, développé en SwiftUI. Identifiant : `com.guilleme.conteur`. L’app nécessite iOS 18 ou une version ultérieure ; l’iPhone 15 Pro sert d’appareil de référence pour les moteurs neuronaux.

## Fonctionnalités

- Bibliothèque locale pour les EPUB sans DRM, les PDF contenant du texte, les fichiers TXT, Markdown et DOCX, ainsi que le texte collé dans l’app.
- Import depuis Fichiers, ouverture directe avec Le Conteur ou **Partager → Le Conteur**. Après un partage, ouvrir l’app permet de retrouver le document dans la bibliothèque.
- Affichage des couvertures EPUB dans la bibliothèque, le lecteur et les éditions traduites.
- Lecture hors ligne avec les voix Apple ou avec des moteurs neuronaux locaux après installation de leurs modèles.
- Affichage des paragraphes, suivi du passage et surlignage des mots. Le défilement suit la ligne courante, même au milieu d’un long paragraphe, et conserve le mot au-dessus des commandes.
- Traduction facultative vers la langue de l’iPhone à l’ouverture d’un livre étranger, avec **Lire l’original** immédiatement disponible.
- Vitesse, signets supprimables individuellement, reprise de lecture, minuterie et commandes sur l’écran verrouillé.

Un livre dans la langue du téléphone s’ouvre directement. Pour un livre étranger sans traduction enregistrée, Le Conteur propose une traduction. **Lire l’original** annule immédiatement et mémorise ce choix. L’original et chaque traduction restent des éditions distinctes dans la bibliothèque, avec leur propre langue, progression et signets. Une traduction partielle reprend uniquement lorsque cette édition est choisie. L’action **Traduire en…** retrouve une traduction existante ou en crée une nouvelle sans imposer de langue globale.

Le livre ouvert le plus récemment est mémorisé séparément de la lecture. Après la fermeture forcée ou la relance de l’app, sa carte, sa couverture et sa position réapparaissent sans démarrer automatiquement l’audio. Supprimer ce livre efface également cette sélection persistante.

Les premiers passages traduits s’ouvrent dès qu’ils sont prêts. La suite est ajoutée au même document sans déplacer les mots ou les signets existants. Si la voix rattrape le texte disponible, elle attend puis reprend automatiquement. Une pause volontaire reste respectée. Quitter le lecteur ou passer l’app en arrière-plan suspend la traduction ; les passages déjà terminés restent lisibles et le travail reprend à la prochaine ouverture de cette édition.

Pendant une traduction active, une voix Apple peut remplacer temporairement un moteur neuronal afin de ne pas conserver deux gros modèles en mémoire. Le lecteur l’indique clairement. Lorsque la traduction se termine ou est suspendue, le moteur choisi revient sans annuler une pause volontaire.

Dans **Voix → Les voix de votre iPhone → Voix préférées par langue**, une étoile désigne la voix Apple préférée de chaque langue. Choisir une voix anglaise ne remplace pas le choix français ou espagnol. Les variantes régionales sont regroupées par langue ; **Automatique** efface uniquement la préférence concernée. Les choix survivent aux relances. Si une voix disparaît, une autre voix disponible de la même langue prend le relais sans supprimer la préférence.

Les aperçus Apple utilisent un texte correspondant à la langue de la voix. La vitesse système est naturelle à 1× ; les autres valeurs restent approximatives, car la vitesse du synthétiseur iOS n’est pas un multiplicateur de lecture. Une conversion bornée évite de saturer sa vitesse maximale à 2×.

Les voix Apple reçoivent plusieurs phrases cohérentes d’un même paragraphe. Les moteurs neuronaux reçoivent des passages bornés et préparent la suite pendant l’écoute. Les phrases exceptionnellement longues conservent les morceaux sûrs créés lors de l’import. Le surlignage préserve les positions dans le texte, y compris avec les caractères Unicode et les écritures sans espaces comme le chinois.

Les couvertures EPUB 3 (`cover-image`), EPUB 2 (`meta name="cover"`) et les pages XHTML/SVG contenant une image matricielle sont prises en charge. Une miniature de 800 pixels au maximum est stockée séparément du texte. Réimporter un ancien EPUB peut récupérer sa couverture sans doublon ni perte de progression. Une couverture purement vectorielle sans image intégrée conserve le visuel générique.

## Lancer sur un iPhone

1. Ouvrir `LeConteur.xcodeproj` dans Xcode et laisser Swift Package Manager résoudre les dépendances.
2. Vérifier dans **Signing & Capabilities** que **LeConteur** et **ConteurShare** utilisent la même équipe de développement.
3. Configurer le groupe `group.com.guilleme.conteur` pour les deux cibles. Il transfère les documents reçus par l’extension de partage.
4. Sélectionner un iPhone et exécuter le schéma **LeConteur**. Run utilise **Release** pour optimiser l’inférence ; les tests utilisent **Debug**. Pour déboguer les variables Swift, choisir Debug dans Edit Scheme → Run.

Aucun modèle neuronal n’est intégré au binaire de production : l’installation s’effectue depuis l’onglet Voix. Le projet utilise iOS 18 comme version minimale et se compile actuellement avec le SDK iOS 27.1.

Le projet utilise `apple-generic` pour le versionnement. Une action préalable à l’archive appelle `agvtool` afin d’incrémenter automatiquement le numéro de build. Une phase de préparation corrige les métadonnées `MinimumOSVersion` du framework ONNX Runtime, le signe de nouveau et produit son dSYM lorsque le format de débogage le demande, afin de rendre l’archive compatible avec App Store Connect.

## Moteurs vocaux

### Supertonic

Supertonic est le moteur neuronal local par défaut. Son modèle s’installe depuis l’onglet Voix et fonctionne entièrement sur l’iPhone. Les passages sont rendus en PCM puis mis en file ; une réserve audio permet de commencer la lecture pendant que la suite se prépare.

iOS limite fortement le CPU dès que Le Conteur n’est plus l’app visible, même si l’écran reste allumé dans une autre app. Supertonic limite donc son calcul en arrière-plan pour éviter que le système ne termine le processus. Il utilise six étapes de diffusion lorsque Le Conteur est visible et quatre en arrière-plan afin de préserver la qualité de narration.

Une réserve préparée réduit les interruptions ; des attentes occasionnelles restent possibles dans une autre app ou écran verrouillé. Sur les iPhone plus anciens, les voix Apple peuvent être préférables pour une lecture indéfiniment continue en arrière-plan.

### Inclusion optionnelle de Qwen

Qwen reste disponible pendant son évaluation et est activé par défaut dans le projet par `CONTEUR_QWEN_CONDITION = CONTEUR_QWEN`. Pour construire une version centrée sur Supertonic et les voix Apple, remplacer cette valeur par `CONTEUR_NO_QWEN` ou la surcharger :

```sh
xcodebuild -project LeConteur.xcodeproj -scheme LeConteur \
  CONTEUR_QWEN_CONDITION=CONTEUR_NO_QWEN build
```

Cette variante masque Qwen, empêche sa sélection et son aperçu, ne crée aucune tâche de téléchargement et migre une ancienne préférence vers Supertonic lorsqu’il est installé, sinon vers Apple. Les poids déjà présents ne sont pas supprimés afin de rendre le changement de variante réversible.

### Qwen sur iPhone

Dans **Voix → Qwen**, choisir un timbre parmi **Ryan, Aiden, Serena, Vivian, Uncle Fu, Ono Anna, Sohee, Dylan et Eric**, puis le style **Chaleureux**, **Naturel** ou **Théâtral**. Les neuf timbres appartiennent au même modèle. La langue native affichée décrit le timbre ; la lecture conserve la langue du livre. Les accents peuvent varier selon la voix.

Les consignes d’intonation sont écrites dans la langue du texte — français, anglais, espagnol, allemand, italien, portugais, russe, japonais, coréen ou chinois — puis envoyées avec la langue explicite. Pour une traduction, il s’agit de la langue cible. Une consigne commune demande une articulation complète et un accent constant, sans pouvoir garantir à elle seule la prononciation du modèle. Les descriptions suivent la [fiche officielle Qwen](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice).

Le modèle est épinglé à `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit`, révision `f35faf19b0cc2160865af64ecf0f22f83d335135`. L’installation Wi-Fi vérifie la taille et le SHA-256 de chaque fichier. Les fichiers terminés survivent à une annulation. Les poids sont stockés dans Application Support, exclus d’iCloud et supprimables depuis l’app. Le texte des livres n’est jamais envoyé au dépôt de modèles.

Le téléchargement utilise une session `URLSessionConfiguration.background` identifiée par `com.guilleme.conteur.voice-downloads.v1`. Les transferts peuvent continuer en Wi-Fi lorsque l’app est suspendue, qu’une autre app est visible ou que l’écran est verrouillé. Les tâches sont récupérées après relance. Les fichiers reçus sont déplacés dans un stockage durable puis vérifiés avant installation. Une fermeture forcée depuis le sélecteur d’apps peut annuler les transferts ; rouvrir l’app reconstruit le travail restant. Voir la [documentation Apple](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

Le paquet local `Packages/ConteurQwen` adapte mlx-audio-swift avec un décodage par blocs de 1,5 seconde, un cache Metal limité à 64 Mio, une annulation sérialisée et un chargement sans l’encodeur audio inutile à CustomVoice. L’app demande la capacité iOS `increased-memory-limit`, vérifie la mémoire disponible avant le chargement et libère le modèle lors des interruptions et avant une traduction.

Qwen met uniquement des passages complets dans le lecteur PCM. **Voix → Qwen → Réserve audio** propose **Automatique, 10 s, 30 s ou 60 s**. Il s’agit de secondes d’écoute à la vitesse choisie : 30 secondes à 2× représentent 60 secondes d’audio source. Le mode automatique estime le temps des prochains rendus et l’écart entre la génération et l’écoute. La génération continue pendant la lecture avec une avance bornée et un maximum de 128 passages.

La lecture démarre dès que la durée cible est prête, même si un seul passage suffit. Une pause volontaire conserve la reprise immédiate de l’audio restant. Une réserve plus grande retarde le démarrage mais réduit les attentes. Si la génération reste plus lente que l’écoute, des pauses peuvent encore survenir.

Une jauge affiche la réserve réellement prête dans le lecteur, le mini-lecteur et l’aperçu. Un rendu en cours n’est compté qu’une fois lisible. Qwen conserve son propre réglage de vitesse, initialement à 2×, avec correction du tempo sans changement de hauteur ni régénération.

La génération Qwen utilise Metal et doit rester au premier plan. Changer d’app ou verrouiller l’écran suspend la génération mais conserve la file PCM, qui continue à jouer. Une fois la réserve vide, Le Conteur attend le retour au premier plan sans basculer silencieusement vers Apple. La préparation reprend au premier passage non généré.

## Traduction

La traduction utilise des blocs de paragraphe bornés et sauvegarde chaque résultat localement. Un indicateur d’activité remplace les pourcentages trompeurs pendant la préparation. Des délais de contrôle arrêtent proprement une session qui ne répond plus. Choisir une nouvelle langue repart toujours de l’original.

Sur les versions iOS actuelles, Le Conteur privilégie la stratégie Apple à faible latence pour la traduction prolongée d’un livre, car elle laisse davantage de ressources au défilement et à la lecture. Lorsqu’un contrôle de disponibilité ne reconnaît pas une paire pourtant offerte par les modèles partagés avec Traduire, l’app retente avec la stratégie compatible et accepte les variantes régionales comme `en-US` ou `en-GB`.

L’inférence est espacée pour protéger la fluidité de l’interface. Les mises à jour de progression sont regroupées afin de ne pas invalider SwiftUI après chaque petit bloc. Les modèles vocaux sont libérés avant la traduction lorsqu’ils sont chargés.

## Limites et composants

Les EPUB protégés par DRM, les PDF chiffrés et les PDF scannés sans couche de texte ne sont pas pris en charge. Limites d’import : 50 Mo et deux millions de caractères. Les traductions sont automatiques et conservées séparément de l’original.

La bibliothèque et les voix téléchargées sont stockées localement et exclues de la sauvegarde iCloud de l’app. Les fichiers originaux choisis dans Fichiers conservent leur propre politique de stockage. Apple peut recueillir des métriques du framework Translation, mais Le Conteur ne lui transmet pas directement le texte des livres.

Dépendances épinglées : ZIPFoundation 0.9.19, MLX Swift 0.32.3, swift-transformers 1.1.6, mlx-audio-swift révision `d8e2cafea891928075d3c8577b1a05b99396594e`, ONNX Runtime et leurs dépendances résolues dans le projet Xcode. Les crédits et licences se trouvent dans `LeConteur/Resources/ThirdPartyNotices.txt`.
