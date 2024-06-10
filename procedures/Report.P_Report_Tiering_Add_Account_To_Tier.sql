--liquibase formatted sql

--changeset Nicolas Griesdorn bfa9aa6d stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             :
--      Author : Jacob Lowe
--             :
--     Created : 2017-09-21
--             :
-- Description : Allows Sales to add Account to tiers
--             :
--       Usage : EXEC [Report].[P_Report_Tiering_Add_Account_to_Tier] 29531, '12862', 0, 0, 'List'
--             :
--  JL20190205 : Add history table
--  JL20190301 : Restrict users
--  JR20190530 : Added block to add records to tables [MarketPlace].[tblAccountBrandedMPTier] and
--             : [MarketPlace].[tblAccountBrandedMPBalance] when the program involves products that
--             : are ordered through the handset ordering tools.
--  JL20190702 : update Restrict users
--  JL20190814 : Removed Restriction for list action
--  JL20191210 : Add Account Infor
--  NG20210521 : Added User Dylan Wethey temporarily
--  NG20210915 : Added User Tyler Fee
--  NG20230504 : Added User Sarah Haver
--  NG20240607 : Added User
-- =============================================
ALTER PROCEDURE [Report].[P_Report_Tiering_Add_Account_to_Tier]
    (
        @sessionUserID INT,
        @Account VARCHAR(MAX),
        @ProgramID INT,
        @TierID INT,
        @Action VARCHAR(50) --List/AddUpdate/Remove
    )
AS
BEGIN TRY

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF (
        NOT EXISTS (

            SELECT 1
            FROM dbo.Users
            WHERE
                User_ID = ISNULL(@sessionUserID, -1)
                AND Account_ID = 2
        ) OR (
            @Action <> 'list'
            --NG20230504
            AND ISNULL(@sessionUserID, 0) NOT IN (
                159497, 225057, 124345, 9915, 10844, 43155, 1243, 25280, 4685, 74734, 75018, 101498, 101508, 264154, 257210, 280015, 343854
            )
        )
    )
        BEGIN
            SELECT 'This User is not authorized to run this process.' AS [Error Message];
            RETURN;
        END;

    IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfAccounts;
        END;

    SELECT
        ID AS [AccountId],
        @TierID AS [Tier]
    INTO #ListOfAccounts
    FROM dbo.fnSplitter(@Account);

    -----------------Begin Add/Update
    IF (@Action = 'AddUpdate')
        BEGIN
        -- Parameter list validation.
            IF (
                ISNULL(@TierID, 0) = 0
                OR ISNULL(@ProgramID, 0) = 0
                OR NOT EXISTS (
                    SELECT 1
                    FROM #ListOfAccounts
                )
            )
                BEGIN
                    SELECT 'Missing one or more inputs.' AS [Error Message];
                    RETURN;
                END;
            -- Program ID validation.
            IF
                NOT EXISTS (
                    SELECT 1
                    FROM Account.tblProgram
                    WHERE ProgramID = ISNULL(@ProgramID, 0)
                )
                BEGIN
                    SELECT 'Invalid Program ID.' AS [Error Message];
                    RETURN;
                END;
            -- Tier ID validation.
            IF
                NOT EXISTS (
                    SELECT 1
                    FROM Account.tblProgramTier
                    WHERE
                        TierID = ISNULL(@TierID, 0)
                        AND ProgramID = @ProgramID
                )
                BEGIN
                    SELECT 'Invalid Tier ID.' AS [Error Message];
                    RETURN;
                END;
            -- Account ID validation.
            IF
                EXISTS (
                    SELECT 1
                    FROM #ListOfAccounts AS lp
                    WHERE
                        NOT EXISTS (
                            SELECT 1
                            FROM dbo.Account AS a
                            WHERE lp.AccountId = a.Account_ID
                        )
                )
                BEGIN
                    SELECT 'Invalid Account ID' AS [Error Message];
                    RETURN;
                END;

            MERGE Account.tblAccountProgram AS T
            USING #ListOfAccounts AS S
                ON
                    T.AccountID = S.AccountId
                    AND T.ProgramID = @ProgramID
            WHEN MATCHED
                THEN
                UPDATE SET T.TierID = S.tier
            WHEN NOT MATCHED BY TARGET
                THEN
                INSERT (AccountID, ProgramID, TierID)
                VALUES (S.AccountId, @ProgramID, S.tier)
            OUTPUT
                Inserted.AccountID,
                GETDATE(),
                CASE
                    WHEN $action = 'INSERT'
                        THEN 'Add'
                    WHEN $action = 'UPDATE'
                        THEN 'Update'
                    ELSE $action
                END,
                CAST(@sessionUserID AS VARCHAR(20)),
                Inserted.TierID
            INTO Account.tblAccountProgramHistory (
                Account_ID,
                CreateDate,
                Action,
                UserID,
                TierID
            );
            DECLARE @addlRecordType INT;

            SELECT @addlRecordType = AdditionalRecord_Type
            FROM Account.tblProgram
            WHERE ProgramID = @ProgramID

            IF (ISNULL(@addlRecordType, 0) <> 0)
                BEGIN
                    IF @addlRecordType IN (1, 2, 7) -- BrandedMPID's that require additional records for handset ordering
                        BEGIN

                            DECLARE @brandedMPID INT = @addlRecordType; -- additional record type maps 1:1 with BrandedMPID

                            DECLARE
                                @brandedMPTierID INT,
                                @tierLevel INT;

                            DECLARE @updateUserID VARCHAR(20) = CAST(@sessionUserID AS VARCHAR(20));

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
                                            SELECT abt.AccountID FROM [MarketPlace].[tblAccountBrandedMPTier] AS abt
                                            WHERE abt.BrandedMPTierID = @brandedMPTierID AND abt.AccountID = la.AccountId
                                        )
                                )
                                BEGIN

                                    MERGE [MarketPlace].[tblAccountBrandedMPTier] AS T
                                    USING #ListOfAccounts AS S
                                        ON T.AccountID = S.AccountId AND BrandedMPTierID = @brandedMPTierID
                                    WHEN NOT MATCHED BY TARGET
                                        THEN
                                        INSERT (AccountID, BrandedMPID, BrandedMPTierID, DateUpdated, UpdateUserID, Status)
                                        VALUES (S.AccountId, @brandedMPID, @brandedMPTierID, GETDATE(), @updateUserID, 1);
                                END

                            IF
                                EXISTS (
                                    SELECT 1 FROM #ListOfAccounts AS la
                                    WHERE
                                        NOT EXISTS (
                                            SELECT abmb.AccountID FROM [MarketPlace].[tblAccountBrandedMPBalance] AS abmb
                                            WHERE abmb.BrandedMPId = @brandedMPID AND abmb.AccountID = la.AccountId
                                        )
                                )
                                BEGIN
                                    INSERT INTO [MarketPlace].[tblAccountBrandedMPBalance] (
                                        AccountID, BrandedMPId, TierLimitTypeId, OutstandingBalance, DateUpdated, UpdateUserID
                                    )
                                    SELECT la.AccountId, @brandedMPID, tl.TierLimitTypeId, 0.00, GETDATE(), @updateUserID -- noqa: AL03
                                    FROM #ListOfAccounts AS la, MarketPlace.tblBrandedMPTierLimit AS tl
                                    WHERE NOT EXISTS (
                                        SELECT abmb.AccountID
                                        FROM [MarketPlace].[tblAccountBrandedMPBalance] AS abmb
                                        WHERE
                                            abmb.BrandedMPId = @brandedMPID
                                            AND la.AccountId = abmb.AccountId
                                    )
                                    AND tl.BrandedMPTierID = @brandedMPTierID
                                END
                        END
                END
        END;
    -------------------END Add/Update
    -------------------Begin Remove
    IF (@Action = 'Remove')
        BEGIN
        -- Parameter list validation.
            IF (
                ISNULL(@ProgramID, 0) = 0
                OR NOT EXISTS
                (
                    SELECT 1
                    FROM #ListOfAccounts
                )
            )
                BEGIN
                    SELECT 'Missing one or more inputs.' AS [Error Message];
                    RETURN;
                END;
            -- Account ID validation.
            IF
                EXISTS
                (
                    SELECT 1
                    FROM #ListOfAccounts AS la
                    WHERE
                        NOT EXISTS
                        (
                            SELECT 1
                            FROM dbo.Account AS a
                            WHERE a.Account_ID = la.AccountId
                        )
                )
                BEGIN
                    SELECT 'Invalid Account ID.' AS [Error Message];
                    RETURN;
                END;

            DELETE FROM Account.tblAccountProgram
            OUTPUT
                Deleted.AccountID,
                GETDATE(),
                'Remove',
                CAST(@sessionUserID AS VARCHAR(20)),
                Deleted.TierID
            INTO Account.tblAccountProgramHistory
            WHERE
                ProgramID = @ProgramID
                AND AccountID IN
                (
                    SELECT la.AccountId FROM #ListOfAccounts AS la
                );

        END;
    -------------------End remove

    SELECT
        a.Account_ID,
        a.Account_Name,
        sh.Address1 AS [ShippingAddress1],
        sh.Address2 AS [ShippingAddress2],
        sh.City AS [ShippingCity],
        sh.State AS [ShippingState],
        sh.Zip AS [ShippingZip],
        sh.Email AS [ShippingEmail],
        con.Phone AS [ContactPhone],
        pt.ProgramID,
        p.Name AS [ProgramName],
        pt.TierID,
        pt.Name AS [TierName],
        pt.Status
    FROM dbo.Account AS a
    JOIN Account.tblAccountProgram AS ap
        ON ap.AccountID = a.Account_ID
    JOIN Account.tblProgramTier AS pt
        ON pt.TierID = ap.TierID
    JOIN Account.tblProgram AS p
        ON p.ProgramID = ap.ProgramID
    JOIN dbo.Customers AS sh ON a.ShipTo = sh.Customer_ID
    JOIN dbo.Customers AS con ON a.Contact_ID = con.Customer_ID
    WHERE (
        EXISTS
        (
            SELECT 1 FROM #ListOfAccounts AS la WHERE la.AccountId = a.Account_ID
        )
        OR NOT EXISTS
        (
            SELECT 1 FROM #ListOfAccounts
        )
    )
    AND
    (
        ap.TierID = @TierID
        OR ISNULL(@TierID, 0) = 0
    )
    AND
    (
        ap.ProgramID = @ProgramID
        OR ISNULL(@ProgramID, 0) = 0
    );

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
    RETURN;
END CATCH;
