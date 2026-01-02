:global LteName "lte1"

:global CheckHost "77.88.8.8"
:global PingCount 3
:global AttachWait 35
:global HoldDownSec 180
:global lastRotate 0

:global eSimListEU {"EU"}
:global eSimListRU {"MTS";"T2"}
:global eSimListAF {"Tunisia"}

:global getMCC do={
  :local info  [/interface lte monitor lte1 once as-value]          
  :local netImsi [:pick ($info->"imsi")   0 3]
  :return [:tonum $netImsi]
}

:global getEsimList do={
  :global eSimListEU
  :global eSimListRU
  :global eSimListAF
  :local currentMcc [$getMCC]
  :if ($currentMcc = 250) do={
      :return $eSimListRU
  } else={
     :if (($currentMcc >= 200) && ($currentMcc < 300)) do={ :return $eSimListEU }
     :if (($currentMcc >= 600) && ($currentMcc < 700)) do={ :return $eSimListAF  }
     :if ([:typeof $currentMcc] = "nil" || [:typeof $currentMcc] = "nothing" ||  $currentMcc = "") do={ :return ($eSimListRU, $eSimListEU, $eSimListAF) }
  }
}


:local nowSec ([:tonum [:timestamp]])

:local elapsed ($nowSec - $lastRotate)
:if ($elapsed < 0) do={ :set elapsed ($elapsed + 86400) }

# 1. Если уже работает — ничего не делаем
:local info [/interface lte monitor $LteName once as-value]

:if ([/ping $CheckHost interface=$LteName count=$PingCount] > 0) do={
    :log info "eSim already work"
  } else={
    :local EsimNickPrio [$getEsimList]
    :log info $EsimNickPrio
    # 2. Антифлап
    :if ($elapsed < $HoldDownSec) do={
        :error ("eSIM: hold-down " . ($HoldDownSec - $elapsed) . "s")
    }

    # 3. Обновим список профилей
    :local activeSimSlot [/interface/lte/settings/get sim-slot]
    :if ($activeSimSlot = "sim") do={ 
        /interface lte settings set sim-slot=esim 
        :log warning "Switching slot to eSim"
        :delay $AttachWait
    }
    /interface lte esim refresh-profile-list interface=$LteName

    :local rows [/interface lte esim print as-value]
    :local rcnt [:len $rows]
    :if ($rcnt = 0) do={
        :error "eSIM: no profiles"
    }

    # 4. Найдём активный профиль
    :local activeNum [/interface/lte/esim/find active]
    :log info "Current active eSim $activeNum"
    # 5. Собираем кандидатов по EsimNickPrio (в нужном порядке)
    :local candidates
    :foreach wantNick in=$EsimNickPrio do={
        :for i from=0 to=($rcnt - 1) do={
                :local row ($rows->$i)
                :local nick ($row->"nickname")
                :if ([:typeof $nick] != "nothing") do={
                    :if ($nick = $wantNick) do={
                            :local num ($row->"number")
                            :if ([:typeof $num] = "nothing") do={ :set num ($row->".id") }
                            :set candidates ($candidates, $num)
                            :log info $candidates
                    }
                }
            }
        }

        :if ([:len $candidates] = 0) do={
            :error "eSIM: no candidates matched EsimNickPrio"
    }

    # 6. Выбираем next после activeNum (или первый)
    :local nextNum ($candidates->0)
    :for j from=0 to=([:len $candidates] - 1) do={
    :if (($candidates->$j) = $activeNum) do={
            :local nj ($j + 1)
            :if ($nj >= [:len $candidates]) do={ :set nj 0 }
            :set nextNum ($candidates->$nj)
        }
    }

    :log warning ("eSIM: switch " . $activeNum . " -> " . $nextNum . " prio=" . $EsimNickPrio)
    /interface lte esim activate number=$nextNum
    :set lastRotate $nowSec

    :delay ($AttachWait . "s")

    # 7. Лог результата (не переключаемся дальше в этом же тике — пусть это сделает следующий запуск)
    :local info2 [/interface lte monitor $LteName once as-value]
    :if (($info2->"status") = "running") do={
        :if ([/ping $CheckHost interface=$LteName count=$PingCount] > 0) do={
            :log info ("eSIM: profile #" . $nextNum . " OK")
        }
    } else={
        :log warning ("eSIM: profile #" . $nextNum . " still not OK")
    }
}
