--liquibase formatted sql

--changeset Nicolas Griesdorn bfa9aa6d stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             :
--      Author : Jacob Lowe
--             :
--     Created : 2017-06-22
--             :
-- Description : Allows Sales to override some funtions
--             :
--       Usage : EXEC [Report].[P_Report_Sales_Account_Send_VZW] 2, 29531, '13379', '', 1, 0, 1, 33, 44, '1'
--             :
--  JL20170717 : Allow sales to update notes
--  JR20170814 : Changed @Status data validation to test against [CarrierSetup].[tblVzwAccountStoreStatus]
--  JL20180323 : Insert into VZW Program if active or unprotected
--  JR20190627 : Added block to add records to tables [MarketPlace].[tblAccountBrandedMPTier] and
--             : [MarketPlace].[tblAccountBrandedMPBalance] when updating.
--  JL20191212 : Add update to Account.tblAccountProgram
--             :
-- KMH20200508 : Change Status 3 to 4. Added 3 new column inputs: Total monthly Activation,
--             : VZW monthly activation forecast, Pref Lang and made these fields mandatory for status 4
--             :
-- KMH20200512 : Total monthly Activation, VZW monthly activation forecast, Pref Lang required if @Action = 1, @Status = 4.
--             : English|1| Hebrew|2| Spanish|3| Arabic|4| Chinese/Mandarin|5| Korean|6|
--             :
--  MR20200520 : Gave the three new columns their own update section not based on if they are a new insert.
--             :
--  MR20200521 : Changed the update for the three new columns to only update if it's a status 4 or if they are not a status 4 with inputs.
--  CH20220521 : Add default values for the nested sp call (otherwise it fails)
--             :
--  JR20230112 : Added support for managing Verizon Tier changes and error messages.
--  JR20230126 : Added support for new history table for tier changes (and UserID parameter).
--  NG20240524 : Updated Closed/Cloned status to work like Closed
-- =============================================
ALTER PROCEDURE [Report].[P_Report_Sales_Account_Send_VZW]
    (
        @SessionAccountID INT,
        @UserID INT,
        @Account VARCHAR(MAX),
        @Notes VARCHAR(MAX),
        @Action BIT,              -- 0 List, 1 Update
        @Status INT,              -- VZW Status
        @VerizonTier INT,              -- VZW Tier
        @TotalMonthlyAct INT = 0,          -- CH20220521
        @VZWMonthlyAct INT = 0,          -- CH20220521
        @PrefLanguage NVARCHAR(25) = '' -- CH20220521
    )
AS
BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF ISNULL(@SessionAccountID, 0) <> 2 --Restrict to Account 2
        BEGIN
            SELECT 'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
            RETURN;
        END;

    IF (ISNULL(@Account, '') = '')
        BEGIN
            SELECT 'Must enter Account ID(s)' AS [Error Message];
            RETURN;
        END;

    -- KMH20200508 Logic check
    IF @Status = 4 AND @Action = 1 AND (ISNULL(@TotalMonthlyAct, 0) = 0 OR ISNULL(@VZWMonthlyAct, 0) = 0 OR ISNULL(@PrefLanguage, '') = '')
        BEGIN
            SELECT 'Must enter Total Monthly Activation, Verizon Monthly Activation' AS [Error Message]
            RETURN;
        END;

    IF NOT EXISTS (SELECT vas.StatusID FROM [CarrierSetup].[tblVzwAccountStoreStatus] AS vas WHERE vas.StatusID = ISNULL(@Status, 0))
        BEGIN
            SELECT 'Invalid Status Entered' AS [Error Message];
            RETURN;
        END;

    IF OBJECT_ID('tempdb..#UpdateResults') IS NOT NULL
        BEGIN
            DROP TABLE #UpdateResults;
        END;

    CREATE TABLE #UpdateResults (
        AccountID INT,
        VzwTier VARCHAR(100),
        TierUpdate VARCHAR(100)
    );

    IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfAccounts;
        END;

    CREATE TABLE #ListOfAccounts (AccountID INT);

    DECLARE @rowCount INT = 0

    INSERT INTO #ListOfAccounts (AccountID)
    SELECT DISTINCT ID FROM dbo.fnSplitter(@Account);

    SET @rowCount = @@ROWCOUNT

    DECLARE @VZW_ID INT = 7; -- Verizon Wireless Carrier ID

    DECLARE @accountId INT = 0

    DECLARE @currentRow INT = 1

    IF (@Action = 1) -- Update
        BEGIN

            WHILE (@currentRow <= @rowCount)
                BEGIN

                    WITH cte AS (
                        SELECT
                            AccountID,
                            ROW_NUMBER() OVER (ORDER BY AccountID) AS RowNum
                        FROM #ListOfAccounts
                    )
                    SELECT @accountId = AccountID
                    FROM cte
                    WHERE RowNum = @currentRow

                    SET @currentRow = @currentRow + 1;

                    IF NOT EXISTS (SELECT 1 FROM dbo.Account WHERE Account_ID = @accountId AND ISNULL(AccountType_ID, 0) IN (2, 11))
                        BEGIN
                            INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                            VALUES (@accountId, '', 'Invalid Account')
                        END
                    ELSE
                        BEGIN

                            IF (
                                @Status = 4 AND EXISTS (
                                    SELECT 1                       -- KMH20200508 Changed from 3
                                    FROM dbo.Account AS ac WITH (NOLOCK)
                                    LEFT JOIN dbo.Customers AS cu WITH (NOLOCK) ON cu.Customer_ID = ac.Contact_ID
                                    WHERE
                                        ac.Account_ID = @accountId
                                        AND (
                                            ISNULL(ac.Account_Name, '') = '' OR
                                            ISNULL(cu.Address1, '') = '' OR
                                            ISNULL(cu.City, '') = '' OR
                                            ISNULL(cu.State, '') = '' OR
                                            ISNULL(cu.Zip, '') = '' OR
                                            ISNULL(cu.Phone, '') = '' OR
                                            ISNULL(cu.Email, '') = '' OR
                                            ISNULL(cu.FirstName, '') = '' OR
                                            ISNULL(cu.LastName, '') = ''
                                        )
                                )
                            )
                                BEGIN
                                    INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                                    VALUES (@accountId, '', 'Account Missing Data')
                                END
                            ELSE
                                BEGIN

                                    IF NOT EXISTS (SELECT 1 FROM CarrierSetup.tblVzwAccountStore WHERE AccountId = @accountId)
                                        BEGIN
                                            INSERT INTO CarrierSetup.tblVzwAccountStore
                                            (
                                                AccountId,
                                                VzwStoreId,
                                                StatusID,
                                                Update_Tms,
                                                OutletID,
                                                Comments
                                            )
                                            SELECT
                                                @accountId, -- noqa: AL03
                                                '64095', -- noqa: AL03
                                                @Status, -- noqa: AL03
                                                GETDATE(), -- noqa: AL03
                                                NULL, -- noqa: AL03
                                                ISNULL(@Notes, '') -- noqa: AL03
                                        END
                                    ELSE
                                        BEGIN
                                            UPDATE vas
                                            SET
                                                vas.StatusID = @Status,
                                                vas.Update_Tms = GETDATE()
                                            OUTPUT
                                                Inserted.AccountId,
                                                Deleted.StatusID,
                                                Inserted.StatusID
                                            INTO
                                                Logs.tblVzwAccountStoreLogs
                                                (
                                                    AccountID,
                                                    OldStatusID,
                                                    NewStatusID
                                                )
                                            FROM CarrierSetup.tblVzwAccountStore AS vas
                                            WHERE
                                                vas.AccountId = @accountId
                                                AND vas.StatusID <> @Status;
                                        END

                                    IF (ISNULL(@Notes, '') <> '')
                                        BEGIN
                                            UPDATE vas
                                            SET vas.Comments = @Notes
                                            FROM CarrierSetup.tblVzwAccountStore AS vas
                                            WHERE vas.AccountId = @accountId
                                        END;

                                    IF @Status = 4
                                        BEGIN
                                            UPDATE vas                        --this update MR20200520
                                            SET
                                                vas.TotalMonthlyActivation = @TotalMonthlyAct,
                                                vas.VZWMonthlyActivationForcast = @VZWMonthlyAct,
                                                vas.PrefLang =
                                                CASE
                                                    WHEN @PrefLanguage = 1 THEN 'English'
                                                    WHEN @PrefLanguage = 2 THEN 'Hebrew'
                                                    WHEN @PrefLanguage = 3 THEN 'Spanish'
                                                    WHEN @PrefLanguage = 4 THEN 'Arabic'
                                                    WHEN @PrefLanguage = 5 THEN 'Chinese/Mandarin'
                                                    WHEN @PrefLanguage = 6 THEN 'Korean'
                                                    ELSE ''
                                                END
                                            FROM CarrierSetup.tblVzwAccountStore AS vas
                                            WHERE vas.AccountId = @accountId
                                        END

                                    IF @Status <> 4 AND ISNULL(@TotalMonthlyAct, 0) <> 0
                                        BEGIN
                                            UPDATE vas                        --this update MR20200521
                                            SET
                                                vas.TotalMonthlyActivation = @TotalMonthlyAct,
                                                vas.VZWMonthlyActivationForcast = @VZWMonthlyAct
                                            FROM CarrierSetup.tblVzwAccountStore AS vas
                                            WHERE vas.AccountId = @accountId
                                        END

                                    IF (@Status IN (0, 7))
                                        BEGIN

                                            IF NOT EXISTS (SELECT 1 FROM Account.tblAccountProgram WHERE AccountID = @accountId AND ProgramID = 2)
                                                BEGIN
                                                    INSERT INTO Account.tblAccountProgram (AccountID, ProgramID, TierID)
                                                    VALUES (@accountId, 2, 2)
                                                END
                                            ELSE
                                                BEGIN
                                                    UPDATE ap
                                                    SET ap.TierID = 2
                                                    FROM Account.tblAccountProgram AS ap
                                                    WHERE
                                                        ap.AccountID = @accountId
                                                        AND ap.ProgramID = 2
                                                        AND ap.TierID <> 2
                                                END

                                            DECLARE @brandedMPID INT = 2

                                            DECLARE
                                                @brandedMPTierID INT,
                                                @tierLevel INT;

                                            DECLARE @updateUserID VARCHAR(20) = CAST(@SessionAccountID AS VARCHAR(20));

                                            SELECT @tierLevel = MIN(TierLevel)
                                            FROM [MarketPlace].[tblBrandedMPTiers]
                                            WHERE BrandedMPID = @brandedMPID
                                            GROUP BY
                                                BrandedMPID

                                                SELECT @brandedMPTierID = BrandedMPTierID
                                                FROM [MarketPlace].[tblBrandedMPTiers]
                                                WHERE
                                                    BrandedMPID = @brandedMPID
                                                    AND TierLevel = @tierLevel

                                            IF
                                                EXISTS (
                                                    SELECT 1 FROM #ListOfAccounts AS la
                                                    WHERE
                                                        NOT EXISTS (
                                                            SELECT abmt.AccountID FROM [MarketPlace].[tblAccountBrandedMPTier] AS abmt
                                                            WHERE
                                                                abmt.BrandedMPTierID = @brandedMPTierID
                                                                AND abmt.AccountID = @accountId
                                                        )
                                                )
                                                BEGIN
                                                    INSERT INTO [MarketPlace].[tblAccountBrandedMPTier] (
                                                        AccountID, BrandedMPID, BrandedMPTierID, DateUpdated, UpdateUserID, Status
                                                    )
                                                    VALUES (@accountId, @brandedMPID, @brandedMPTierID, GETDATE(), @updateUserID, 1);
                                                END

                                            IF
                                                EXISTS (
                                                    SELECT 1 FROM #ListOfAccounts AS la
                                                    WHERE
                                                        NOT EXISTS (
                                                            SELECT abmb.AccountID FROM [MarketPlace].[tblAccountBrandedMPBalance] AS abmb
                                                            WHERE abmb.BrandedMPId = @brandedMPID AND abmb.AccountID = @accountId
                                                        )
                                                )
                                                BEGIN
                                                    INSERT INTO [MarketPlace].[tblAccountBrandedMPBalance] (
                                                        AccountID, BrandedMPId, TierLimitTypeId, OutstandingBalance, DateUpdated, UpdateUserID
                                                    )
                                                    SELECT @accountId, @brandedMPID, tl.TierLimitTypeId, 0.00, GETDATE(), @updateUserID -- noqa: AL03
                                                    FROM #ListOfAccounts AS la, MarketPlace.tblBrandedMPTierLimit AS tl
                                                    WHERE NOT EXISTS (
                                                        SELECT abmb.AccountID
                                                        FROM [MarketPlace].[tblAccountBrandedMPBalance] AS abmb
                                                        WHERE
                                                            abmb.BrandedMPId = @brandedMPID
                                                            AND abmb.AccountID = @accountId
                                                    )
                                                    AND la.AccountID = @accountId
                                                    AND tl.BrandedMPTierID = @brandedMPTierID
                                                END

                                        END;

                                    IF (@Status IN (2, 5, 8, 9, 10, 11, 255))     -- NG20240524 Added 10
                                        BEGIN
                                            DELETE FROM Account.tblAccountProgram
                                            WHERE
                                                ProgramID = 2
                                                AND AccountID = @accountId
                                        END;

                                    -- JR20230112
                                    IF
                                        EXISTS (
                                            SELECT
                                                1 FROM [CarrierSetup].[tblVzwAccountStore] WHERE
                                                AccountId = @accountId AND StatusID <> 0
                                                AND @Status <> 0
                                        )
                                        BEGIN
                                            INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                                            VALUES (@accountId, '', 'Account NOT VZW Active')
                                        END
                                    ELSE
                                        BEGIN
                                            IF @VerizonTier = 0
                                                BEGIN
                                                    IF
                                                        EXISTS (
                                                            SELECT 1
                                                            FROM [Account].[tblAccountTier]
                                                            WHERE Account_ID = @accountId AND Carrier_Id = @VZW_ID
                                                        )
                                                        BEGIN
                                                            UPDATE ta
                                                            SET
                                                                ta.User_Id = @UserID,
                                                                ta.Update_Date = GETDATE(),
                                                                ta.Update_Action = 'Removed'
                                                            FROM [Account].[tblAccountTier] AS ta
                                                            JOIN #ListOfAccounts AS la
                                                                ON
                                                                    ta.Account_ID = la.AccountID
                                                                    AND ta.Carrier_Id = @VZW_ID
                                                                    AND la.AccountID = @accountId
                                                            DELETE
                                                            FROM [Account].[tblAccountTier]
                                                            WHERE
                                                                Account_ID = @accountId
                                                                AND Carrier_Id = @VZW_ID

                                                            INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                                                            VALUES (@accountId, '', 'Tier Removed')
                                                        END
                                                    ELSE
                                                        BEGIN
                                                            INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                                                            VALUES (@accountId, '', '-n/a-')
                                                        END
                                                END
                                            ELSE
                                                BEGIN
                                                    IF
                                                        EXISTS (
                                                            SELECT 1
                                                            FROM [Account].[tblAccountTier]
                                                            WHERE Account_ID = @accountId AND Carrier_Id = @VZW_ID
                                                        )
                                                        BEGIN
                                                            UPDATE ta
                                                            SET
                                                                ta.User_Id = @UserID,
                                                                ta.Update_Date = GETDATE(),
                                                                ta.TierId = @VerizonTier,
                                                                ta.Update_Action = 'Updated'
                                                            FROM [Account].[tblAccountTier] AS ta
                                                            JOIN #ListOfAccounts AS la
                                                                ON
                                                                    ta.Account_ID = la.AccountID
                                                                    AND ta.Carrier_Id = @VZW_ID
                                                                    AND la.AccountID = @accountId

                                                            INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                                                            VALUES (@accountId, CAST(@VerizonTier AS VARCHAR(10)), 'Tier Updated')
                                                        END
                                                    ELSE
                                                        BEGIN
                                                            INSERT INTO [Account].[tblAccountTier] (
                                                                Account_Id, TierId, Carrier_Id, User_Id, Update_Action, Update_Date
                                                            )
                                                            VALUES (@accountId, @VerizonTier, @VZW_ID, @UserID, 'Inserted', GETDATE())

                                                            INSERT INTO #UpdateResults (AccountID, VzwTier, TierUpdate)
                                                            VALUES (@accountId, CAST(@VerizonTier AS VARCHAR(10)), 'Tier Inserted')
                                                        END
                                                END
                                        END
                                END
                        END
                END

            SELECT
                la.AccountID,
                ISNULL(vass.Description, '-n/a-') AS [Description],
                ISNULL(vt.Name, '-n/a-') AS [VZW Tier],
                ISNULL(ur.TierUpdate, '') AS [Tier Update],
                vas.Comments,
                vas.TotalMonthlyActivation,                                                            -- KMH20200508 Added 3 new columns to output
                vas.VZWMonthlyActivationForcast,
                vas.PrefLang

            FROM #ListOfAccounts AS la
            LEFT JOIN CarrierSetup.tblVzwAccountStore AS vas ON vas.AccountId = la.AccountID
            LEFT JOIN CarrierSetup.tblVzwAccountStoreStatus AS vass
                ON
                    vass.StatusID = vas.StatusID
                    AND vass.StatusID <> 255

            LEFT JOIN [Account].[tblAccountTier] AS tr ON tr.Account_Id = la.AccountID
            LEFT JOIN [CarrierSetup].[tblTier] AS vt ON vt.TierId = tr.TierId

            LEFT JOIN #UpdateResults AS ur ON la.AccountID = ur.AccountID

            RETURN;
        END;

    SELECT
        la.AccountID,
        ISNULL(vass.Description, '-n/a-') AS [Description],
        ISNULL(vt.Name, '-n/a-') AS [VZW Tier],
        vas.Comments,
        vas.TotalMonthlyActivation,                                                            -- KMH20200508 Added 3 new columns to output
        vas.VZWMonthlyActivationForcast,
        vas.PrefLang
    FROM #ListOfAccounts AS la
    LEFT JOIN CarrierSetup.tblVzwAccountStore AS vas ON vas.AccountId = la.AccountID
    LEFT JOIN CarrierSetup.tblVzwAccountStoreStatus AS vass
        ON
            vass.StatusID = vas.StatusID
            AND vass.StatusID <> 255

    LEFT JOIN [Account].[tblAccountTier] AS tr ON tr.Account_Id = la.AccountID
    LEFT JOIN [CarrierSetup].[tblTier] AS vt ON vt.TierId = tr.TierId

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
    RETURN;
END CATCH;
